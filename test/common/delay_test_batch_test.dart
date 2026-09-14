import 'dart:async';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/delay_test.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a constrained link recovers failed targets with lower retry concurrency',
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
        retryProbe: (target, timeout) async {
          expect(initialFinished, targets.length);
          expect(timeout, lessThanOrEqualTo(delayRetryTimeout));
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
      retryProbe: (target, _) async {
        retries++;
        return Delay(name: target.name, url: target.url, value: -1);
      },
      onResult: results.add,
    );
    expect(retries, 1);
    expect(results.single.value, -1);
  });

  test('only failed targets retry after all initial probes', () async {
    final attempts = <String, int>{};
    final results = <String, int?>{};
    var active = 0;
    var peak = 0;
    Future<Delay> probe(({String name, String url}) target) async {
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
    }

    await runDelayTestBatch(
      targets: List.generate(5, (i) => (name: '$i', url: 'url')),
      concurrency: 2,
      isCurrent: () => true,
      probe: probe,
      retryProbe: (target, _) => probe(target),
      onResult: (delay) => results[delay.name] = delay.value,
    );
    expect(peak, 2);
    expect(attempts, {'0': 2, '1': 2, '2': 1, '3': 1, '4': 1});
    expect(results, {'0': -1, '1': 25, '2': 25, '3': 25, '4': 25});
  });

  test(
    'generation change discards pending result and prevents queued probes',
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
        retryProbe: (_, _) => throw StateError('Unexpected retry'),
        onResult: results.add,
      );
      current = false;
      pending.complete(const Delay(name: 'one', url: 'url', value: -1));
      await run;
      expect(calls, 1);
      expect(results, isEmpty);
    },
  );

  test('initial results are delivered before a slow peer finishes', () async {
    final slow = Completer<Delay>();
    final results = <Delay>[];
    final run = runDelayTestBatch(
      targets: [
        (name: 'fast', url: 'url'),
        (name: 'failed', url: 'url'),
        (name: 'slow', url: 'url'),
      ],
      concurrency: 3,
      retryBudget: Duration.zero,
      isCurrent: () => true,
      probe: (target) async => target.name == 'slow'
          ? slow.future
          : Delay(
              name: target.name,
              url: target.url,
              value: target.name == 'failed' ? -1 : 20,
            ),
      retryProbe: (_, _) => throw StateError('Unexpected retry'),
      onResult: results.add,
    );
    await pumpEventQueue();
    expect(results.map((delay) => delay.name), ['fast', 'failed']);
    slow.complete(const Delay(name: 'slow', url: 'url', value: 30));
    await run;
    expect(results.map((delay) => delay.name), ['fast', 'failed', 'slow']);
  });

  test(
    'cancellation during retry suppresses late recovery and queued work',
    () async {
      final retry = Completer<Delay>();
      var current = true;
      var calls = 0;
      final results = <Delay>[];
      final run = runDelayTestBatch(
        targets: [(name: 'one', url: 'url'), (name: 'two', url: 'url')],
        concurrency: 2,
        isCurrent: () => current,
        probe: (target) async =>
            Delay(name: target.name, url: target.url, value: -1),
        retryProbe: (_, _) {
          calls++;
          return retry.future;
        },
        onResult: results.add,
      );
      await pumpEventQueue();
      expect(calls, 1);
      expect(results.map((delay) => delay.value), [-1, -1]);
      current = false;
      retry.complete(const Delay(name: 'one', url: 'url', value: 25));
      await run;
      expect(results.map((delay) => delay.value), [-1, -1]);
      expect(calls, 1);
    },
  );

  for (final (platform, concurrency, retryConcurrency, firstPassSeconds) in [
    ('desktop', maxConcurrentDelayTests, 8, 10),
    ('Android', mobileDelayTestConcurrency, 4, 25),
  ]) {
    testWidgets(
      '100 unreachable $platform nodes finish without a long retry queue',
      (tester) async {
        final results = <String, int?>{};
        var finished = false;
        var initialCalls = 0;
        var retries = 0;
        var active = 0;
        var peak = 0;
        final run = runDelayTestBatch(
          targets: List.generate(100, (i) => (name: '$i', url: 'url')),
          concurrency: concurrency,
          retryConcurrency: retryConcurrency,
          createStopwatch: tester.binding.clock.stopwatch,
          isCurrent: () => true,
          probe: (target) async {
            initialCalls++;
            active++;
            if (active > peak) peak = active;
            await Future<void>.delayed(httpTimeoutDuration);
            active--;
            return Delay(name: target.name, url: target.url, value: -1);
          },
          retryProbe: (target, timeout) async {
            expectSync(initialCalls, 100);
            retries++;
            await Future<void>.delayed(timeout);
            return Delay(name: target.name, url: target.url, value: -1);
          },
          onResult: (delay) => results[delay.name] = delay.value,
        ).then((_) => finished = true);
        for (var elapsed = 0; elapsed < firstPassSeconds; elapsed += 5) {
          await tester.pump(httpTimeoutDuration);
        }
        expect(results.length, 100);
        expect(results.values, everyElement(-1));
        expect(finished, isFalse);
        await tester.pump(delayRetryTimeout);
        expect(finished, isTrue);
        expect(retries, retryConcurrency);
        expect(peak, concurrency);
        await run;
      },
    );
  }

  testWidgets('slow successful nodes retain first-pass concurrency', (
    tester,
  ) async {
    final results = <Delay>[];
    var finished = false;
    final run = runDelayTestBatch(
      targets: List.generate(48, (i) => (name: '$i', url: 'url')),
      concurrency: mobileDelayTestConcurrency,
      isCurrent: () => true,
      probe: (target) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        return Delay(name: target.name, url: target.url, value: 3000);
      },
      retryProbe: (_, _) => throw StateError('Unexpected retry'),
      onResult: results.add,
    ).then((_) => finished = true);
    await tester.pump(const Duration(seconds: 3));
    expect(results.length, 24);
    await tester.pump(const Duration(seconds: 3));
    expect(finished, isTrue);
    expect(results.length, 48);
    await run;
  });

  testWidgets('later retries receive only the remaining shared time', (
    tester,
  ) async {
    final budgets = <Duration>[];
    final results = <String, int?>{};
    var finished = false;
    final run = runDelayTestBatch(
      targets: List.generate(4, (i) => (name: '$i', url: 'url')),
      concurrency: 4,
      createStopwatch: tester.binding.clock.stopwatch,
      isCurrent: () => true,
      probe: (target) async =>
          Delay(name: target.name, url: target.url, value: -1),
      retryProbe: (target, timeout) async {
        budgets.add(timeout);
        const needed = Duration(seconds: 7);
        final recovered = timeout >= needed;
        await Future<void>.delayed(recovered ? needed : timeout);
        return Delay(
          name: target.name,
          url: target.url,
          value: recovered ? 7000 : -1,
        );
      },
      onResult: (delay) => results[delay.name] = delay.value,
    ).then((_) => finished = true);
    await tester.pump();
    expect(results, {'0': -1, '1': -1, '2': -1, '3': -1});
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(seconds: 1));
    expect(finished, isTrue);
    expect(budgets, [
      const Duration(seconds: 15),
      const Duration(seconds: 8),
      const Duration(seconds: 1),
    ]);
    expect(results, {'0': 7000, '1': 7000, '2': -1, '3': -1});
    await run;
  });
}
