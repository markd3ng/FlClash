import 'dart:async';
import 'package:fl_clash/common/delay_test.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a constrained link recovers failed targets with a separate retry budget',
    () async {
      var active = 0;
      var retries = 0;
      var retryPeak = 0;
      var initialFinished = 0;
      final results = <String, int?>{};
      final targets = List.generate(12, (i) => (name: '$i', url: 'url'));
      await runDelayTestBatch(
        targets: targets,
        concurrency: 4,
        retryConcurrency: 2,
        isCurrent: () => true,
        probe: (target) async {
          active++;
          final congested = active > 2;
          await Future<void>.delayed(Duration.zero);
          active--;
          initialFinished++;
          return Delay(
            name: target.name,
            url: target.url,
            value: congested ? -1 : 2500,
          );
        },
        retryProbe: (target) async {
          expect(initialFinished, targets.length);
          active++;
          retries++;
          if (active > retryPeak) retryPeak = active;
          await Future<void>.delayed(Duration.zero);
          active--;
          return Delay(name: target.name, url: target.url, value: 6500);
        },
        onResult: (delay) => results[delay.name] = delay.value,
      );
      expect(retries, greaterThan(0));
      expect(retryPeak, lessThanOrEqualTo(2));
      expect(results.length, targets.length);
      expect(results.values, everyElement(greaterThan(0)));
      expect(results.values, contains(6500));
    },
  );

  test('a long-budget retry keeps a truly unreachable node failed', () async {
    final results = <Delay>[];
    var retries = 0;
    await runDelayTestBatch(
      targets: [(name: 'offline', url: 'url')],
      concurrency: 4,
      isCurrent: () => true,
      probe: (target) async =>
          Delay(name: target.name, url: target.url, value: -1),
      retryProbe: (target) async {
        retries++;
        return Delay(name: target.name, url: target.url, value: -1);
      },
      onResult: results.add,
    );
    expect(retries, 1);
    expect(results.single.value, -1);
  });
  test(
    'failed probes retry once after initial work with serial concurrency',
    () async {
      final attempts = <String, int>{};
      final results = <String, int?>{};
      var active = 0;
      var peak = 0;
      await runDelayTestBatch(
        targets: List.generate(
          5,
          (i) => (name: '$i', url: 'https://example.com'),
        ),
        concurrency: 2,
        isCurrent: () => true,
        probe: (target) async {
          final attempt = attempts.update(
            target.name,
            (n) => n + 1,
            ifAbsent: () => 1,
          );
          active++;
          if (active > peak) peak = active;
          if (attempt == 2) {
            expect(attempts.length, 5);
            expect(active, 1);
          }
          await Future<void>.delayed(Duration.zero);
          active--;
          return Delay(
            name: target.name,
            url: target.url,
            value: target.name == '0' || (attempt == 1 && target.name == '1')
                ? -1
                : 25,
          );
        },
        onResult: (delay) => results[delay.name] = delay.value,
      );
      expect(peak, 2);
      expect(attempts, {'0': 2, '1': 2, '2': 1, '3': 1, '4': 1});
      expect(results, {'0': -1, '1': 25, '2': 25, '3': 25, '4': 25});
    },
  );

  test(
    'generation change discards pending result and prevents retry or queued probes',
    () async {
      var current = true;
      var calls = 0;
      final pending = Completer<Delay>();
      final results = <Delay>[];
      final run = runDelayTestBatch(
        targets: [(name: 'one', url: 'url'), (name: 'two', url: 'url')],
        concurrency: 1,
        isCurrent: () => current,
        probe: (_) {
          calls++;
          return pending.future;
        },
        onResult: results.add,
      );
      current = false;
      pending.complete(const Delay(name: 'one', url: 'url', value: -1));
      await run;
      expect(calls, 1);
      expect(results, isEmpty);
    },
  );
  test(
    'successful results are delivered before a slow peer finishes',
    () async {
      final slow = Completer<Delay>();
      final results = <Delay>[];
      final run = runDelayTestBatch(
        targets: [(name: 'fast', url: 'url'), (name: 'slow', url: 'url')],
        concurrency: 2,
        isCurrent: () => true,
        probe: (target) async => target.name == 'slow'
            ? slow.future
            : const Delay(name: 'fast', url: 'url', value: 20),
        onResult: results.add,
      );
      await pumpEventQueue();
      expect(results.map((delay) => delay.name), ['fast']);
      slow.complete(const Delay(name: 'slow', url: 'url', value: 30));
      await run;
      expect(results.map((delay) => delay.name), ['fast', 'slow']);
    },
  );

  test(
    'cancellation during retry suppresses its result and further retries',
    () async {
      final retry = Completer<Delay>();
      var current = true;
      var calls = 0;
      final results = <Delay>[];
      final run = runDelayTestBatch(
        targets: [(name: 'one', url: 'url'), (name: 'two', url: 'url')],
        concurrency: 2,
        isCurrent: () => current,
        probe: (target) async {
          calls++;
          if (calls > 2) return retry.future;
          return Delay(name: target.name, url: target.url, value: -1);
        },
        onResult: results.add,
      );
      await pumpEventQueue();
      expect(calls, 3);
      expect(results, isEmpty);
      current = false;
      retry.complete(const Delay(name: 'one', url: 'url', value: 25));
      await run;
      expect(results, isEmpty);
      expect(calls, 3);
    },
  );
}
