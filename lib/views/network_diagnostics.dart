import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/services/network_diagnostics.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

final networkDiagnosticReportHeaderProvider = Provider<String>((ref) {
  final info = globalState.packageInfo;
  return 'FlClash ${info.version}+${info.buildNumber} (${Platform.operatingSystem})';
});

final networkDiagnosticServiceProvider = Provider<NetworkDiagnosticService>(
  (ref) => NetworkDiagnosticService(),
);
final networkDiagnosticSnapshotProvider = Provider<NetworkDiagnosticSnapshot>((
  ref,
) {
  final profile = ref.watch(currentProfileProvider);
  final patch = ref.watch(patchClashConfigProvider);
  return NetworkDiagnosticSnapshot(
    profileApplied:
        profile != null && globalState.lastSetupState?.profileId == profile.id,
    running: ref.watch(isStartProvider),
    suspended: ref.watch(suspendProvider),
    systemProxy: ref.watch(proxyStateProvider).systemProxy,
    tun: patch.tun.enable,
    oixCloud: profile?.isoixCloudProfile ?? false,
    port: patch.mixedPort,
  );
});

void showNetworkDiagnostics(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const NetworkDiagnosticsPage()),
  );
}

class NetworkDiagnosticsPage extends ConsumerStatefulWidget {
  const NetworkDiagnosticsPage({super.key});
  @override
  ConsumerState<NetworkDiagnosticsPage> createState() =>
      _NetworkDiagnosticsPageState();
}

class _NetworkDiagnosticsPageState
    extends ConsumerState<NetworkDiagnosticsPage> {
  final _checks = <NetworkDiagnosticCheck>[];
  CancelToken? _token;
  bool _running = false;
  bool _canceled = false;
  DateTime? _started;

  @override
  void initState() {
    super.initState();
    ref.listenManual(networkDiagnosticSnapshotProvider, (_, _) {
      if (_running && mounted) {
        _token?.cancel();
        setState(() => _canceled = true);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_run());
    });
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final token = CancelToken();
    _token = token;
    setState(() {
      _checks.clear();
      _running = true;
      _canceled = false;
      _started = DateTime.now();
    });
    try {
      await ref
          .read(networkDiagnosticServiceProvider)
          .run(
            ref.read(networkDiagnosticSnapshotProvider),
            token,
            onResult: (check) {
              if (mounted && !token.isCancelled) {
                setState(() => _checks.add(check));
              }
            },
          );
    } catch (_) {
      if (mounted && !token.isCancelled) {
        setState(
          () => _checks.add(
            NetworkDiagnosticCheck(
              'unavailable',
              context.appLocalizations.diagTitle,
              DiagnosticStatus.unknown,
              context.appLocalizations.diagUnknown,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  String _status(DiagnosticStatus status) => switch (status) {
    DiagnosticStatus.passed => context.appLocalizations.diagPassed,
    DiagnosticStatus.warning => context.appLocalizations.diagWarning,
    DiagnosticStatus.failed => context.appLocalizations.diagFailed,
    DiagnosticStatus.unknown => context.appLocalizations.diagUnknown,
    DiagnosticStatus.skipped => context.appLocalizations.diagSkipped,
  };

  String _report() => [
    '${ref.read(networkDiagnosticReportHeaderProvider)} — ${context.appLocalizations.diagTitle}',
    _started?.toIso8601String() ?? '',
    if (_canceled) context.appLocalizations.diagCanceled,
    context.appLocalizations.diagScope,
    for (final check in _checks) ...[
      '\n[${_status(check.status)}] ${check.title}',
      check.detail,
      if (check.suggestion != null) check.suggestion!,
    ],
  ].join('\n');

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    return CommonScaffold(
      title: l.diagTitle,
      actions: [
        IconButton(
          tooltip: l.diagCopy,
          onPressed: _checks.isEmpty || _running
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: _report()));
                  if (context.mounted) context.showNotifier(l.copySuccess);
                },
          icon: const Icon(Icons.copy),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.diagScope),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.network_check),
                label: Text(l.diagRun),
              ),
              if (_running)
                OutlinedButton(
                  onPressed: () {
                    _token?.cancel();
                    setState(() {
                      _canceled = true;
                    });
                  },
                  child: Text(l.cancel),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_running) const LinearProgressIndicator(),
          if (_canceled)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l.diagCanceled),
            ),
          for (final check in _checks)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          switch (check.status) {
                            DiagnosticStatus.passed =>
                              Icons.check_circle_outline,
                            DiagnosticStatus.failed => Icons.error_outline,
                            DiagnosticStatus.warning => Icons.warning_amber,
                            _ => Icons.help_outline,
                          },
                          color: switch (check.status) {
                            DiagnosticStatus.passed => Colors.green,
                            DiagnosticStatus.failed =>
                              context.colorScheme.error,
                            DiagnosticStatus.warning => Colors.orange,
                            _ => context.colorScheme.onSurfaceVariant,
                          },
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${check.title} · ${_status(check.status)}',
                            style: context.textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(check.detail),
                    if (check.suggestion != null) ...[
                      const SizedBox(height: 8),
                      Text(check.suggestion!),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
