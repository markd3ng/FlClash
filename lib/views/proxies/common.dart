import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/delay_test.dart';
import 'package:fl_clash/common/network_failure_prompt.dart';
import 'package:fl_clash/views/network_diagnostics.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';

final _networkFailurePrompt = NetworkFailurePromptGate();

double get listHeaderHeight {
  final measure = globalState.measure;
  return 20 + measure.titleMediumHeight + 4 + measure.bodyMediumHeight + 2;
}

double getItemHeight(ProxyCardType proxyCardType) {
  final measure = globalState.measure;
  final baseHeight =
      16 + measure.bodyMediumHeight * 2 + measure.bodySmallHeight + 8 + 4;
  return switch (proxyCardType) {
    ProxyCardType.expand => baseHeight + measure.labelSmallHeight + 6,
    ProxyCardType.shrink => baseHeight,
    ProxyCardType.min => baseHeight - measure.bodyMediumHeight,
  };
}

Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) {
  return _runDelayTests([proxy], testUrl);
}

Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) {
  return _runDelayTests(proxies, testUrl, sortResults: true);
}

Future<void> _runDelayTests(
  List<Proxy> proxies,
  String? testUrl, {
  bool sortResults = false,
}) async {
  final delayTargets = computeDelayTestTargets(
    proxies: proxies,
    groups: appController.groups,
    selectedMap: appController.currentProfile?.selectedMap ?? {},
    defaultTestUrl: appController.getRealTestUrl(testUrl),
  );
  if (delayTargets.isEmpty) {
    return;
  }
  final profileId = appController.currentProfile?.id;
  final runSession = globalState.startTime;
  final completed = <(String, String), int?>{};
  final nodeTargets = delayTargets
      .where(
        (target) =>
            !const {'DIRECT', 'REJECT', 'COMPATIBLE'}.contains(target.name),
      )
      .toList();
  final generation = appController.beginDelayTest();
  appController.setDelays(
    delayTargets.map(
      (target) => Delay(url: target.url, name: target.name, value: 0),
    ),
    generation: generation,
  );

  await runDelayTestBatch(
    targets: delayTargets,
    concurrency: maxConcurrentDelayTests,
    probe: (target) => coreController.getDelay(
      target.url,
      target.name,
      isCurrent: () => appController.isCurrentDelayGeneration(generation),
    ),
    isCurrent: () => appController.isCurrentDelayGeneration(generation),
    onResult: (delay) {
      completed[(delay.name, delay.url)] = delay.value;
      appController.setDelay(delay, generation: generation);
    },
  );
  if (appController.isCurrentDelayGeneration(generation)) {
    if (sortResults) appController.addSortNum();
    appController.updateGroupsDebounce();
    if (sortResults &&
        (system.isWindows || system.isMacOS) &&
        _networkFailurePrompt.observe(
          session: (profileId, runSession),
          expected: nodeTargets.length,
          results: nodeTargets.map(
            (target) => completed[(target.name, target.url)],
          ),
          current:
              profileId == appController.currentProfile?.id &&
              runSession == globalState.startTime,
          running: appController.isProxyActive,
        )) {
      globalState.showNotifier(
        appLocalizations.diagAllFailed,
        actionState: MessageActionState(
          actionText: appLocalizations.diagTitle,
          action: () {
            final context = globalState.navigatorKey.currentContext;
            if (context != null && context.mounted) {
              showNetworkDiagnostics(context);
            }
          },
        ),
      );
    }
  }
}

double getScrollToSelectedOffset({
  required String groupName,
  required List<Proxy> proxies,
}) {
  final columns = appController.getProxiesColumns();
  final proxyCardType = appController.config.proxiesStyleProps.cardType;
  final selectedProxyName = appController.getSelectedProxyName(groupName);
  final findSelectedIndex = proxies.indexWhere(
    (proxy) => proxy.name == selectedProxyName,
  );
  final selectedIndex = findSelectedIndex != -1 ? findSelectedIndex : 0;
  final rows = (selectedIndex / columns).floor();
  return rows * getItemHeight(proxyCardType) + (rows - 1) * 8;
}
