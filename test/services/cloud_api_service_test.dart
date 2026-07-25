import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/http.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('delete account request includes confirmation and optional TOTP', () {
    expect(
      buildDeleteAccountRequestData(
        password: 'secret',
        twoFactorCode: ' 123456 ',
      ),
      {'passwd': 'secret', 'confirmation': 'DELETE', 'code': '123456'},
    );

    expect(buildDeleteAccountRequestData(password: 'secret'), {
      'passwd': 'secret',
      'confirmation': 'DELETE',
    });
  });

  test('managed config prefers direct with a ready core fallback', () {
    expect(
      resolveManagedConfigProxy(
        isCoreRunning: true,
        hasProxyGroups: true,
        port: 7890,
      ),
      'DIRECT; PROXY localhost:7890',
    );

    for (final state in [
      (running: false, groups: true, port: 7890),
      (running: true, groups: false, port: 7890),
      (running: true, groups: true, port: 0),
    ]) {
      expect(
        resolveManagedConfigProxy(
          isCoreRunning: state.running,
          hasProxyGroups: state.groups,
          port: state.port,
        ),
        'DIRECT',
      );
    }
  });

  test('hedged adapter drains a response that loses the race', () async {
    final inner = _RacingAdapter();
    final adapter = HedgedApiAdapter(
      inner,
      domains: () => const ['primary.test', 'spare.test'],
    );

    final response = await adapter.fetch(
      RequestOptions(baseUrl: 'https://primary.test', path: '/profile'),
      null,
      null,
    );

    expect(await response.stream.single, Uint8List.fromList([2]));
    await inner.losingResponseDrained.future.timeout(
      const Duration(seconds: 1),
    );
  });

  test('hedged adapter sends a non-idempotent request only once', () async {
    final inner = _CountingAdapter();
    final adapter = HedgedApiAdapter(
      inner,
      domains: () => const ['primary.test', 'spare.test'],
    );

    final response = await adapter.fetch(
      RequestOptions(
        baseUrl: 'https://primary.test',
        path: '/login',
        extra: {cloudNonIdempotentExtraKey: true},
      ),
      null,
      null,
    );

    expect(await response.stream.single, Uint8List.fromList([1]));
    expect(inner.fetchCount, 1);
  });
}

class _RacingAdapter implements HttpClientAdapter {
  final losingResponseDrained = Completer<void>();

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.host == 'spare.test') {
      return ResponseBody.fromBytes([2], 200);
    }

    await Future<void>.delayed(const Duration(milliseconds: 300));
    late StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () {
        losingResponseDrained.complete();
        controller
          ..add(Uint8List.fromList([1]))
          ..close();
      },
    );
    return ResponseBody(controller.stream, 200);
  }
}

class _CountingAdapter implements HttpClientAdapter {
  var fetchCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return ResponseBody.fromBytes([1], 200);
  }
}
