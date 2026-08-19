import 'dart:io';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('method envelopes use structured arguments and results', () {
    const call = CoreMethodCall(
      id: 'updateConfig#contract',
      method: CoreMethod.updateConfig,
      arguments: {'mixed-port': 7890, 'allow-lan': true},
    );
    final encoded = call.toJson();

    expect(encoded['arguments'], isA<Map<String, Object?>>());
    expect(encoded, isNot(contains('data')));
    expect(CoreMethodCall.fromJson(encoded).method, CoreMethod.updateConfig);

    const response = CoreMethodResponse(
      id: 'getTraffic#contract',
      result: {'up': 12, 'down': 34},
    );
    expect(response.unwrap<Map<String, dynamic>>()?['up'], 12);
  });

  test('method errors remain structured', () {
    const response = CoreMethodResponse(
      id: 'getConfig#contract',
      error: CoreMethodError(
        code: 'core_error',
        message: 'config not found',
        details: {'path': '/missing.yaml'},
      ),
    );

    expect(
      () => response.unwrap<Object?>(),
      throwsA(
        isA<CoreMethodException>()
            .having((error) => error.code, 'code', 'core_error')
            .having((error) => error.details, 'details', {
              'path': '/missing.yaml',
            }),
      ),
    );
  });

  test('event contract accepts batches', () {
    final events = coreEventsFromData([
      {'type': 'loaded', 'data': 'provider-a'},
      {
        'type': 'delay',
        'data': {
          'name': 'proxy-a',
          'url': 'http://cp.cloudflare.com/generate_204',
          'value': 42,
        },
      },
    ]);

    expect(events, hasLength(2));
    expect(events.first.type, CoreEventType.loaded);
    expect(events.last.type, CoreEventType.delay);
  });

  test('Dart methods match the Go protocol and Action is removed', () async {
    final constants = await File('core/constant.go').readAsString();
    for (final method in CoreMethod.values) {
      expect(
        constants,
        contains('= "${method.name}"'),
        reason: 'Go Core is missing ${method.name}',
      );
    }

    expect(await File('core/method.go').readAsString(), contains('MethodCall'));
    expect(File('core/action.go').existsSync(), isFalse);
  });
}
