import 'dart:async';

import 'package:fl_clash/common/proxy.dart';
import 'package:test/test.dart';

void main() {
  test(
    'checks once for a persisted proxy even before a successful start',
    () async {
      var stops = 0;
      final controller = SystemProxyController(
        startProxy: (_, _) async => false,
        stopProxy: () async {
          stops++;
          return true;
        },
      );

      await controller.start(7890, const []);
      await controller.stopIfNeeded();
      await controller.stopIfNeeded();

      expect(controller.startedByFlClash, false);
      expect(stops, 1);
    },
  );

  test('keeps ownership until proxy restoration succeeds', () async {
    var restoreSucceeds = false;
    final controller = SystemProxyController(
      startProxy: (_, _) async => true,
      stopProxy: () async => restoreSucceeds,
    );

    await controller.start(7890, const []);
    expect(controller.startedByFlClash, true);

    await controller.stopIfNeeded();
    expect(controller.startedByFlClash, true);

    restoreSucceeds = true;
    await controller.stopIfNeeded();
    expect(controller.startedByFlClash, false);
  });

  test('rechecks persisted state after a failed start', () async {
    var stops = 0;
    final controller = SystemProxyController(
      startProxy: (_, _) async => false,
      stopProxy: () async {
        stops++;
        return true;
      },
    );

    await controller.stopIfNeeded();
    await controller.start(7890, const []);
    await controller.stopIfNeeded();

    expect(stops, 2);
  });

  test('serializes start and stop requests', () async {
    final releaseStart = Completer<void>();
    final events = <String>[];
    final controller = SystemProxyController(
      startProxy: (_, _) async {
        events.add('start');
        await releaseStart.future;
        events.add('started');
        return true;
      },
      stopProxy: () async {
        events.add('stop');
        return true;
      },
    );

    final start = controller.start(7890, const []);
    final stop = controller.stopIfNeeded();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['start']);

    releaseStart.complete();
    await Future.wait([start, stop]);
    expect(events, ['start', 'started', 'stop']);
    expect(controller.startedByFlClash, false);
  });
}
