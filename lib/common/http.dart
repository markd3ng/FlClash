import 'dart:io';

import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';

String resolveCloudApiProxy({
  required bool isCoreRunning,
  required bool hasProxyGroups,
  required int port,
}) {
  if (!isCoreRunning || !hasProxyGroups || port <= 0) {
    return 'DIRECT';
  }
  return 'DIRECT; PROXY localhost:$port';
}

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
      client.badCertificateCallback = (_, _, _) =>
          allowBadCertificate?.call() ?? false;
      client.findProxy = (uri) {
        final ua = userAgent?.call();
        if (ua != null && ua.isNotEmpty) {
          client.userAgent = ua;
        }
        return findProxy(uri);
      };
      return client;
    },
  );
}

class FlClashHttpOverrides extends HttpOverrides {
  static bool _isLocalHost(String host) {
    final normalizedHost = host.trim().toLowerCase();
    return normalizedHost == localhost ||
        normalizedHost == 'localhost' ||
        (InternetAddress.tryParse(normalizedHost)?.isLoopback ?? false);
  }

  static String handleFindProxy(Uri url) {
    if (_isLocalHost(url.host) || Secrets.isApiDomain(url.host)) {
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

  static String handleCloudApiFindProxy(Uri url) {
    if (!Secrets.isApiDomain(url.host) ||
        !system.isDesktop ||
        !appController.isAttach) {
      return 'DIRECT';
    }
    final port = appController.config.patchClashConfig.mixedPort;
    return resolveCloudApiProxy(
      isCoreRunning: appController.isStart,
      hasProxyGroups: appController.groups.isNotEmpty,
      port: port,
    );
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (_, _, _) =>
        FlClashTemporaryTls.allowBadCertificate;
    client.findProxy = handleFindProxy;
    return client;
  }
}
