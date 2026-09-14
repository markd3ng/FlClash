import 'package:fl_clash/models/models.dart';

typedef DelayProbe = Future<Delay> Function(({String name, String url}) target);

/// Back off after slow/failed probes, then retry only failed targets with a
/// separate network budget. A generation change stops queued work and results.
Future<void> runDelayTestBatch({
  required List<({String name, String url})> targets,
  required int concurrency,
  required DelayProbe probe,
  DelayProbe? retryProbe,
  int retryConcurrency = 1,
  required bool Function() isCurrent,
  required void Function(Delay delay) onResult,
}) async {
  if (concurrency <= 0 || retryConcurrency <= 0) {
    throw ArgumentError('Probe concurrency must be positive');
  }
  final failed = <({String name, String url})>[];
  var next = 0;
  var limit = concurrency;
  var consecutiveFailures = 0;
  Future<void> worker(int index) async {
    while (isCurrent() && next < targets.length && index < limit) {
      final target = targets[next++];
      final delay = await probe(target);
      if (!isCurrent()) return;
      if ((delay.value ?? -1) <= 0) {
        failed.add(target);
        consecutiveFailures++;
      } else {
        consecutiveFailures = 0;
        onResult(delay);
      }
      // A pair of failures or a slow handshake is enough to stop filling the
      // link with new probes. Already active work can finish normally.
      if (limit > 2 &&
          (consecutiveFailures >= 2 || (delay.value ?? 0) >= 2000)) {
        limit = 2;
      }
    }
  }

  await Future.wait(
    List.generate(
      targets.length < concurrency ? targets.length : concurrency,
      worker,
    ),
  );
  next = 0;
  Future<void> retryWorker() async {
    while (isCurrent() && next < failed.length) {
      final target = failed[next++];
      final delay = await (retryProbe ?? probe)(target);
      if (!isCurrent()) return;
      onResult(delay);
    }
  }

  await Future.wait(
    List.generate(
      failed.length < retryConcurrency ? failed.length : retryConcurrency,
      (_) => retryWorker(),
    ),
  );
}
