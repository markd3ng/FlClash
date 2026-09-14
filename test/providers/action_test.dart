import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/views/profiles/add.dart';
import 'package:fl_clash/widgets/pop_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import '../helpers/test_app.dart';

class _ProfileAction extends ProfileAction {
  int imports = 0;
  @override
  Future<void> addProfileFormFile() async {
    imports++;
  }
}

class _BackAction extends BackBlockAction {
  int balance = 0;
  @override
  void backBlock() {
    balance++;
  }

  @override
  void unBackBlock() {
    balance--;
  }
}

class _WindowPort implements WindowPort {
  int toggles = 0;
  @override
  Future<void> toggle() async {
    toggles++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('visibility actions use the serialized window toggle', () async {
    final previous = windowPort;
    final port = _WindowPort();
    windowPort = port;
    addTearDown(() => windowPort = previous);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(systemActionProvider.notifier).updateVisible();
    expect(port.toggles, 1);
  });

  testWidgets('profile import uses the action from its own ProviderScope', (
    tester,
  ) async {
    final action = _ProfileAction();
    final other = ProviderContainer(
      overrides: [profileActionProvider.overrideWith(_ProfileAction.new)],
    );
    addTearDown(other.dispose);
    final otherAction =
        other.read(profileActionProvider.notifier) as _ProfileAction;
    await tester.pumpWidget(
      TestApp(
        overrides: [profileActionProvider.overrideWith(() => action)],
        child: Scaffold(
          body: Builder(builder: (context) => AddProfileView(context: context)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(appLocalizations.file));
    await tester.pump();
    expect(action.imports, 1);
    expect(otherAction.imports, 0);
  });

  testWidgets('back blocking is balanced after its widget is removed', (
    tester,
  ) async {
    final action = _BackAction();
    final show = ValueNotifier(true);
    addTearDown(show.dispose);
    await tester.pumpWidget(
      TestApp(
        overrides: [backBlockActionProvider.overrideWith(() => action)],
        child: ValueListenableBuilder(
          valueListenable: show,
          builder: (_, value, _) => value
              ? const SystemBackBlock(child: SizedBox())
              : const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    expect(action.balance, 1);
    show.value = false;
    await tester.pump();
    await tester.pump();
    expect(action.balance, 0);
    expect(tester.takeException(), isNull);
  });
}
