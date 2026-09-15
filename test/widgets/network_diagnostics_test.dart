import 'dart:async';
import 'package:dio/dio.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/services/network_diagnostics.dart';
import 'package:fl_clash/views/network_diagnostics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _snapshot = NetworkDiagnosticSnapshot(
  profileApplied: true,
  running: true,
  suspended: false,
  systemProxy: true,
  tun: false,
  oixCloud: true,
  port: 7890,
);

class _ControlledService extends NetworkDiagnosticService {
  final completion = Completer<void>();
  CancelToken? token;
  int runs = 0;
  @override
  Future<List<NetworkDiagnosticCheck>> run(
    NetworkDiagnosticSnapshot state,
    CancelToken cancellation, {
    required void Function(NetworkDiagnosticCheck) onResult,
  }) async {
    runs++;
    token = cancellation;
    onResult(
      const NetworkDiagnosticCheck(
        'fixture',
        'oixCloud DNS',
        DiagnosticStatus.failed,
        'DNS lookup failed (System error 11001)',
        'Check DNS settings and system time',
      ),
    );
    await completion.future;
    onResult(
      const NetworkDiagnosticCheck(
        'late',
        'Late check',
        DiagnosticStatus.passed,
        'Late result',
      ),
    );
    return [];
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _ControlledService service,
) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        networkDiagnosticReportHeaderProvider.overrideWithValue(
          'FlClash 0.8.97+fixture (windows)',
        ),
        networkDiagnosticServiceProvider.overrideWithValue(service),
        networkDiagnosticSnapshotProvider.overrideWithValue(_snapshot),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.delegate.supportedLocales,
        home: const NetworkDiagnosticsPage(),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(
    tester.element(find.byType(NetworkDiagnosticsPage)),
  );
}

void main() {
  testWidgets(
    'shows concrete cause and suggestion, then copies a bounded report',
    (tester) async {
      final service = _ControlledService();
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(tester, service);
      expect(
        find.text('DNS lookup failed (System error 11001)'),
        findsOneWidget,
      );
      expect(find.text('Check DNS settings and system time'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      service.completion.complete();
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.tap(find.byTooltip(AppLocalizations.current.diagCopy));
      await tester.pump();
      expect(clipboard, contains('[Failed] oixCloud DNS'));
      expect(clipboard, contains('0.8.97+fixture (windows)'));
      expect(clipboard, contains('11001'));
      expect(clipboard, isNot(contains('7890')));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cancel prevents late results and allows a fresh run', (
    tester,
  ) async {
    final service = _ControlledService();
    await _pump(tester, service);
    await tester.tap(find.text(AppLocalizations.current.cancel));
    await tester.pump();
    expect(service.token!.isCancelled, isTrue);
    service.completion.complete();
    await tester.pumpAndSettle();
    expect(find.text('Late result'), findsNothing);
    expect(find.text(AppLocalizations.current.diagCanceled), findsOneWidget);
    await tester.tap(find.text(AppLocalizations.current.diagRun));
    await tester.pumpAndSettle();
    expect(service.runs, 2);
    expect(find.text(AppLocalizations.current.diagCanceled), findsNothing);
  });
  testWidgets('configuration changes cancel a running snapshot', (
    tester,
  ) async {
    final service = _ControlledService();
    final container = await _pump(tester, service);
    container.updateOverrides([
      networkDiagnosticReportHeaderProvider.overrideWithValue(
        'FlClash 0.8.97+fixture (windows)',
      ),
      networkDiagnosticServiceProvider.overrideWithValue(service),
      networkDiagnosticSnapshotProvider.overrideWithValue(
        const NetworkDiagnosticSnapshot(
          profileApplied: true,
          running: true,
          suspended: false,
          systemProxy: true,
          tun: true,
          oixCloud: true,
          port: 7890,
        ),
      ),
    ]);
    await tester.pump();
    expect(service.token!.isCancelled, isTrue);
    service.completion.complete();
    await tester.pumpAndSettle();
    expect(find.text('Late result'), findsNothing);
  });
  testWidgets(
    'closing the page cancels probes without updating disposed state',
    (tester) async {
      final service = _ControlledService();
      await _pump(tester, service);
      await tester.pumpWidget(const SizedBox());
      expect(service.token!.isCancelled, isTrue);
      service.completion.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('results fit a narrow window and large text', (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final service = _ControlledService()..completion.complete();
    await _pump(tester, service);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
