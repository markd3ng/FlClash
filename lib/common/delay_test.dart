import 'package:fl_clash/models/models.dart';

typedef DelayProbe = Future<Delay> Function(({String name, String url}) target);
typedef DelayRetryProbe =
    Future<Delay> Function(
      ({String name, String url}) target,
      Duration timeout,
    );

/// Publish each initial result immediately, then retry failed targets within a
/// shared network budget. A generation change stops queued work and results.
Future<void> runDelayTestBatch({
  required List<({String name, String url})> targets,
  required int concurrency,
  required DelayProbe probe,
  required DelayRetryProbe retryProbe,
  int retryConcurrency = 1,
  Duration retryBudget = const Duration(seconds: 15),
  Stopwatch Function() createStopwatch = Stopwatch.new,
  required bool Function() isCurrent,
  required void Function(Delay delay) onResult,
}) async {
  if (concurrency <= 0 || retryConcurrency <= 0) {
    throw ArgumentError('Probe concurrency must be positive');
  }
  if (retryBudget.isNegative) {
    throw ArgumentError.value(
      retryBudget,
      'retryBudget',
      'Must not be negative',
    );
  }
  final failed = <({String name, String url})>[];
  var next = 0;
  Future<void> worker() async {
    while (isCurrent() && next < targets.length) {
      final target = targets[next++];
      final delay = await probe(target);
      if (!isCurrent()) return;
      onResult(delay);
      if ((delay.value ?? -1) <= 0) {
        failed.add(target);
      }
    }
  }

  await Future.wait(
    List.generate(
      targets.length < concurrency ? targets.length : concurrency,
      (_) => worker(),
    ),
  );
  if (!isCurrent() || failed.isEmpty || retryBudget == Duration.zero) return;

  // The budget belongs to the whole recovery pass, not to every failed node.
  // Keep initial failures visible when no time remains to retry them.
  final stopwatch = createStopwatch()..start();
  next = 0;
  Future<void> retryWorker() async {
    while (isCurrent() && next < failed.length) {
      final timeout = retryBudget - stopwatch.elapsed;
      // Avoid rounding a sub-millisecond network budget down to zero.
      if (timeout.inMilliseconds <= 0) return;
      final target = failed[next++];
      final delay = await retryProbe(target, timeout);
      if (!isCurrent()) return;
      if ((delay.value ?? -1) > 0) onResult(delay);
    }
  }

  try {
    await Future.wait(
      List.generate(
        failed.length < retryConcurrency ? failed.length : retryConcurrency,
        (_) => retryWorker(),
      ),
    );
  } finally {
    stopwatch.stop();
  }
}
