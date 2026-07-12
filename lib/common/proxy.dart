import 'dart:async';

import 'package:fl_clash/common/system.dart';
import 'package:proxy/proxy.dart';

final proxy = system.isDesktop ? Proxy() : null;

typedef SystemProxyStarter =
    Future<bool?> Function(int port, List<String> bypassDomain);
typedef SystemProxyStopper = Future<bool?> Function();

class SystemProxyController {
  final SystemProxyStarter? _startProxy;
  final SystemProxyStopper? _stopProxy;

  bool _startedByFlClash = false;
  bool _checkedPersistedState = false;
  Future<void> _task = Future.value();

  SystemProxyController({
    required SystemProxyStarter? startProxy,
    required SystemProxyStopper? stopProxy,
  }) : _startProxy = startProxy,
       _stopProxy = stopProxy;

  bool get startedByFlClash => _startedByFlClash;

  Future<bool> start(int port, List<String> bypassDomain) {
    final startProxy = _startProxy;
    if (startProxy == null) return Future.value(true);

    return _queue(() async {
      _checkedPersistedState = false;
      final success = await startProxy(port, bypassDomain);
      if (success == true) {
        _startedByFlClash = true;
        _checkedPersistedState = true;
      }
      return success == true;
    });
  }

  Future<bool> stopIfNeeded() {
    final stopProxy = _stopProxy;
    if (stopProxy == null) return Future.value(true);

    return _queue(() async {
      if (!_startedByFlClash && _checkedPersistedState) return true;

      final success = await stopProxy();
      if (success == true) {
        _startedByFlClash = false;
        _checkedPersistedState = true;
      }
      return success == true;
    });
  }

  Future<T> _queue<T>(Future<T> Function() task) {
    final operation = _task.then((_) => task());
    _task = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }
}

Future<bool> startSystemProxy(int port, List<String> bypassDomain) {
  return systemProxyController.start(port, bypassDomain);
}

Future<bool> stopSystemProxyIfNeeded() {
  return systemProxyController.stopIfNeeded();
}

final systemProxyController = SystemProxyController(
  startProxy: proxy?.startProxy,
  stopProxy: proxy?.stopProxy,
);
