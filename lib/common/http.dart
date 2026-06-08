import 'dart:io';

import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';

class FlClashTemporaryTls {
  const FlClashTemporaryTls._();

  static int _badCertificateDepth = 0;

  static bool get allowBadCertificate => _badCertificateDepth > 0;

  static Future<T> runWithBadCertificateAllowed<T>(
    Future<T> Function() action,
  ) async {
    _badCertificateDepth++;
    try {
      return await action();
    } finally {
      _badCertificateDepth--;
    }
  }

  static bool isCertificateVerifyFailed(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('certificate_verify_failed') ||
        message.contains('handshakeexception') ||
        message.contains('handshake error') ||
        message.contains('bad certificate') ||
        message.contains('invalid certificate') ||
        message.contains('unable to get local issuer certificate');
  }
}

IOHttpClientAdapter createFlClashHttpClientAdapter({
  required String Function(Uri uri) findProxy,
  bool Function()? allowBadCertificate,
  String? Function()? userAgent,
}) {
  return IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      bool allowBadCertificateCallback() =>
          allowBadCertificate?.call() ?? false;
      client.badCertificateCallback = (_, _, _) =>
          allowBadCertificateCallback();
      client.findProxy = (uri) {
        final ua = userAgent?.call();
        if (ua != null && ua.isNotEmpty) {
          client.userAgent = ua;
        }
        return findProxy(uri);
      };
      client.connectionFactory = (uri, proxyHost, proxyPort) {
        return FlClashHostOverrides.connect(
          uri,
          proxyHost,
          proxyPort,
          onBadCertificate: (_) => allowBadCertificateCallback(),
        );
      };
      return client;
    },
  );
}

class FlClashHostOverrides {
  const FlClashHostOverrides._();

  static String? resolve(String host) {
    return Secrets.resolveHostOverride(host);
  }

  static Future<ConnectionTask<Socket>> connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, {
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
  }) async {
    final hasProxy = proxyHost != null;
    final targetHost = hasProxy ? proxyHost : resolve(uri.host) ?? uri.host;
    final targetPort = hasProxy ? proxyPort! : uri.port;
    if (!hasProxy && uri.isScheme('https')) {
      final socketTask = await Socket.startConnect(targetHost, targetPort);
      final secureSocket = socketTask.socket.then(
        (socket) => SecureSocket.secure(
          socket,
          host: uri.host,
          context: context,
          onBadCertificate: onBadCertificate,
        ),
      );
      return ConnectionTask.fromSocket<Socket>(secureSocket, socketTask.cancel);
    }
    return Socket.startConnect(targetHost, targetPort);
  }
}

class FlClashHttpOverrides extends HttpOverrides {
  static bool _isLocalHost(String host) {
    final normalizedHost = host.trim().toLowerCase();
    return normalizedHost == localhost ||
        normalizedHost == 'localhost' ||
        (InternetAddress.tryParse(normalizedHost)?.isLoopback ?? false);
  }

  static String handleFindProxy(Uri url) {
    final isApiDomain = Secrets.isApiDomain(url.host);
    if (_isLocalHost(url.host) || isApiDomain) {
      return 'DIRECT';
    }
    final port = appController.config.patchClashConfig.mixedPort;
    final isStart = appController.isStart;
    final displayUrl = Uri(
      scheme: url.scheme,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: url.path,
    );
    commonPrint.log('find $displayUrl proxy:$isStart');
    if (!isStart) return 'DIRECT';
    return 'PROXY localhost:$port';
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    bool allowBadCertificateCallback() =>
        FlClashTemporaryTls.allowBadCertificate;
    client.badCertificateCallback = (_, _, _) => allowBadCertificateCallback();
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      return FlClashHostOverrides.connect(
        uri,
        proxyHost,
        proxyPort,
        context: context,
        onBadCertificate: (_) => allowBadCertificateCallback(),
      );
    };
    client.findProxy = handleFindProxy;
    return client;
  }
}
