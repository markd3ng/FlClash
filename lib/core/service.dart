import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/core.dart';

import 'interface.dart';
import 'ipc_cipher.dart';
import 'ipc_frame.dart';

class CoreService extends CoreHandlerInterface {
  static const _coreStartTimeout = Duration(seconds: 10);
  static const _coreStopTimeout = Duration(seconds: 5);

  static CoreService? _instance;

  final Completer<ServerSocket> _serverCompleter = Completer();

  Completer<Socket> _socketCompleter = Completer();

  final Map<String, Completer> _callbackCompleterMap = {};

  Socket? _socket;

  Process? _process;
  bool _startedByHelper = false;
  Future<void> _lifecycleTail = Future.value();

  // Per-session key for the local core IPC socket. Handed to the core
  // out-of-band via the FLCLASH_IPC_KEY env var so it never crosses the socket.
  final List<int> _ipcKey = IpcCipher.generateKey();
  late final IpcCipher _ipc = IpcCipher(_ipcKey);

  factory CoreService() {
    _instance ??= CoreService._internal();
    return _instance!;
  }

  CoreService._internal() {
    _initServer();
  }

  Future<void> handleResult(ActionResult result) async {
    final completer = _callbackCompleterMap[result.id];
    final data = await parasResult(result);
    if (result.id?.isEmpty == true) {
      coreEventManager.sendEvent(CoreEvent.fromJson(result.data));
    }
    if (completer?.isCompleted == true) {
      return;
    }
    completer?.complete(data);
  }

  Future<void> _initServer() async {
    final server = await retry(
      task: () async {
        try {
          final address = !system.isWindows
              ? InternetAddress(unixSocketPath, type: InternetAddressType.unix)
              : InternetAddress(localhost, type: InternetAddressType.IPv4);
          await _deleteSocketFile();
          final server = await ServerSocket.bind(address, 0, shared: true);
          server.listen((socket) async {
            await _attachSocket(socket);
          });
          return server;
        } catch (_) {
          return null;
        }
      },
      retryIf: (server) => server == null,
    );
    if (server == null) {
      exit(0);
    }
    _serverCompleter.complete(server);
  }

  Future<void> _attachSocket(Socket socket) async {
    final previous = _socket;
    _socket = socket;
    if (_socketCompleter.isCompleted) {
      _socketCompleter = Completer();
    }
    final decoder = IpcFrameDecoder();
    socket
        .listen((chunk) async {
          final List<Uint8List> frames;
          try {
            frames = decoder.add(chunk);
          } on FormatException {
            socket.destroy();
            return;
          }
          for (final frame in frames) {
            final plain = await _ipc.decodeFrame(frame);
            if (plain == null) {
              continue;
            }
            final dataJson = await plain.commonToJSON<dynamic>();
            handleResult(ActionResult.fromJson(dataJson));
          }
        })
        .onDone(() {
          if (_resetSocketIfCurrent(socket)) {
            _clearCompleter();
            _handleInvokeCrashEvent();
          }
        });
    _socketCompleter.complete(socket);
    if (previous != null) {
      await previous.close();
    }
  }

  bool _resetSocketIfCurrent(Socket socket) {
    if (identical(_socket, socket)) {
      _socket = null;
      _socketCompleter = Completer();
      return true;
    }
    return false;
  }

  void _handleInvokeCrashEvent() {
    coreEventManager.sendEvent(
      const CoreEvent(type: CoreEventType.crash, data: 'socket done'),
    );
  }

  Future<T> _serializeLifecycle<T>(Future<T> Function() action) {
    final operation = _lifecycleTail.then((_) => action());
    _lifecycleTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> start() {
    return _serializeLifecycle(_startUnlocked);
  }

  Future<void> _startUnlocked() async {
    if (_process != null || _startedByHelper) {
      await _shutdownUnlocked(false);
    }
    final serverSocket = await _serverCompleter.future;
    final arg = system.isWindows
        ? '${serverSocket.port}'
        : serverSocket.address.address;
    if (system.isWindows && await system.checkIsAdmin()) {
      final isSuccess = await request.startCoreByHelper(
        arg,
        base64.encode(_ipcKey),
      );
      if (isSuccess) {
        _startedByHelper = true;
        try {
          await _waitForConnection();
          return;
        } catch (_) {
          final stopped = await request.stopCoreByHelper();
          if (stopped) _startedByHelper = false;
          rethrow;
        }
      }
    }
    try {
      final process = await Process.start(
        appPath.corePath,
        [arg],
        environment: {'FLCLASH_IPC_KEY': base64.encode(_ipcKey)},
      );
      _process = process;
      unawaited(
        process.exitCode.then((code) {
          commonPrint.log('Core process exited with code: $code');
        }),
      );
      process.stdout.listen((_) {});
      process.stderr.listen((e) {
        final error = utf8.decode(e);
        if (error.isNotEmpty) {
          commonPrint.log(error, logLevel: LogLevel.warning);
        }
      });
      await _waitForConnection(process: process);
    } catch (e) {
      commonPrint.log(
        'Failed to start core process: $e',
        logLevel: LogLevel.error,
      );
      _handleInvokeCrashEvent();
      final failedProcess = _process;
      if (failedProcess != null && await _stopLocalProcess(failedProcess)) {
        if (identical(_process, failedProcess)) _process = null;
      }
      rethrow;
    }
  }

  Future<void> _waitForConnection({Process? process}) async {
    final connectionFuture = _socketCompleter.future.then<void>((_) {});
    final startupFutures = <Future<void>>[connectionFuture];
    if (process != null) {
      startupFutures.add(
        process.exitCode.then<void>((code) {
          if (!_socketCompleter.isCompleted) {
            throw StateError('Core process exited before connecting: $code');
          }
        }),
      );
    }
    await Future.any(startupFutures).timeout(_coreStartTimeout);
    if (!_socketCompleter.isCompleted) {
      throw StateError('Core process did not connect');
    }
  }

  @override
  Future<bool> destroy() async {
    final server = await _serverCompleter.future;
    await shutdown(false);
    await server.close();
    await _deleteSocketFile();
    return true;
  }

  Future<void> sendMessage(String message) async {
    final socket = await _socketCompleter.future;
    socket.add(encodeIpcFrame(await _ipc.encodeFrame(message)));
  }

  Future<void> _deleteSocketFile() async {
    if (!system.isWindows) {
      final file = File(unixSocketPath);
      await file.safeDelete();
    }
  }

  Future<void> _destroySocket() async {
    final socket = _socket;
    _socket = null;
    if (_socketCompleter.isCompleted) {
      _socketCompleter = Completer();
    }
    if (socket != null) {
      await socket.close();
    }
  }

  @override
  Future<bool> shutdown(bool isUser) {
    return _serializeLifecycle(() => _shutdownUnlocked(isUser));
  }

  Future<bool> _shutdownUnlocked(bool isUser) async {
    if (!_socketCompleter.isCompleted &&
        _process == null &&
        !_startedByHelper) {
      return false;
    }
    final process = _process;
    await _destroySocket();
    _clearCompleter();
    if (system.isWindows && _startedByHelper) {
      final stopped = await request.stopCoreByHelper();
      if (stopped) _startedByHelper = false;
      return stopped;
    }
    if (process == null) {
      return false;
    }
    final stopped = await _stopLocalProcess(process);
    if (!stopped) return false;
    if (identical(_process, process)) {
      _process = null;
    }
    return true;
  }

  Future<bool> _stopLocalProcess(Process process) async {
    process.kill();
    try {
      await process.exitCode.timeout(_coreStopTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(_coreStopTimeout);
      } on TimeoutException {
        return false;
      }
    }
    return true;
  }

  void _clearCompleter() {
    for (final completer in _callbackCompleterMap.values) {
      completer.safeCompleter(null);
    }
  }

  @override
  Future<String> preload() async {
    await _serverCompleter.future;
    try {
      await start();
      return '';
    } catch (e) {
      return e.toString();
    }
  }

  @override
  Future<T?> invoke<T>({
    required ActionMethod method,
    dynamic data,
    Duration? timeout,
  }) async {
    final id = '${method.name}#${utils.id}';
    _callbackCompleterMap[id] = Completer<T?>();
    sendMessage(json.encode(Action(id: id, method: method, data: data)));
    return (_callbackCompleterMap[id] as Completer<T?>).future.withTimeout(
      timeout: timeout,
      onLast: () {
        final completer = _callbackCompleterMap[id];
        completer?.safeCompleter(null);
        _callbackCompleterMap.remove(id);
      },
      tag: id,
      onTimeout: () => null,
    );
  }

  @override
  Completer get completer => _socketCompleter;
}

final coreService = system.isDesktop ? CoreService() : null;
