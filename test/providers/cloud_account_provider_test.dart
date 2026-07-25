import 'dart:async';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/cloud_account_provider.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('failed token revocation preserves the signed-in session', () async {
    final notifier = _DeleteNotifier(
      logoutError: const CloudApiException('Revocation failed'),
    );
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final success = await container
        .read(cloudAccountProvider.notifier)
        .signOut(revokeToken: true);
    final state = container.read(cloudAccountProvider);

    expect(success, false);
    expect(state.isLoggedIn, true);
    expect(state.isLoading, false);
    expect(state.error, 'Revocation failed');
    expect(notifier.didClearSession, false);
  });

  test('token revocation keeps the account busy until it completes', () async {
    final completer = Completer<void>();
    final notifier = _DeleteNotifier(logoutCompleter: completer);
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final signOut = container
        .read(cloudAccountProvider.notifier)
        .signOut(revokeToken: true);

    expect(container.read(cloudAccountProvider).isLoading, true);
    completer.complete();
    expect(await signOut, true);
    expect(notifier.didClearSession, true);
  });

  test('local cleanup failure is reported after signing out', () async {
    final notifier = _DeleteNotifier(cleanupError: 'Secure storage failed');
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final success = await container
        .read(cloudAccountProvider.notifier)
        .signOut();
    final state = container.read(cloudAccountProvider);

    expect(success, false);
    expect(state.isLoggedIn, false);
    expect(state.error, 'Secure storage failed');
  });

  test('sign out does not race an active managed profile sync', () async {
    final notifier = _DeleteNotifier(
      initialState: const CloudAccountState(isLoggedIn: true, isSyncing: true),
    );
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final success = await container
        .read(cloudAccountProvider.notifier)
        .signOut();

    expect(success, false);
    expect(notifier.didClearSession, false);
    expect(container.read(cloudAccountProvider).isLoggedIn, true);
  });

  test('unauthorized cleanup is not blocked by active sync state', () async {
    final notifier = _DeleteNotifier(
      initialState: const CloudAccountState(isLoggedIn: true, isSyncing: true),
    );
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    await container.read(cloudAccountProvider.notifier).handleUnauthorized();

    expect(notifier.didClearSession, true);
    expect(container.read(cloudAccountProvider).isLoggedIn, false);
  });

  test('failed account deletion preserves the signed-in session', () async {
    final notifier = _DeleteNotifier(
      requestError: const CloudApiException('Incorrect password'),
    );
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final success = await container
        .read(cloudAccountProvider.notifier)
        .deleteAccount(password: 'wrong');
    final state = container.read(cloudAccountProvider);

    expect(success, false);
    expect(state.isLoggedIn, true);
    expect(state.isLoading, false);
    expect(state.error, 'Incorrect password');
    expect(notifier.didClearSession, false);
  });

  test('unauthorized account deletion clears the invalid session', () async {
    final notifier = _DeleteNotifier(
      requestError: const CloudApiException('Unauthorized'),
    );
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final success = await container
        .read(cloudAccountProvider.notifier)
        .deleteAccount(password: 'secret');
    final state = container.read(cloudAccountProvider);

    expect(success, false);
    expect(state.isLoggedIn, false);
    expect(state.isLoading, false);
    expect(state.error, 'Unauthorized');
    expect(notifier.didClearSession, true);
  });

  test('successful account deletion clears the local session', () async {
    final notifier = _DeleteNotifier();
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final success = await container
        .read(cloudAccountProvider.notifier)
        .deleteAccount(password: 'secret', twoFactorCode: '123456');

    expect(success, true);
    expect(container.read(cloudAccountProvider).isLoggedIn, false);
    expect(notifier.requestCount, 1);
    expect(notifier.didClearSession, true);
  });

  test('account deletion reports a local cleanup failure', () async {
    final notifier = _DeleteNotifier(cleanupError: 'Secure storage failed');
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final success = await container
        .read(cloudAccountProvider.notifier)
        .deleteAccount(password: 'secret');
    final state = container.read(cloudAccountProvider);

    expect(success, false);
    expect(state.isLoggedIn, false);
    expect(state.error, 'Secure storage failed');
    expect(notifier.didClearSession, true);
  });

  test('account deletion does not race an active refresh', () async {
    final notifier = _DeleteNotifier(
      initialState: const CloudAccountState(
        isLoggedIn: true,
        isRefreshing: true,
      ),
    );
    final container = ProviderContainer(
      overrides: [cloudAccountProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final success = await container
        .read(cloudAccountProvider.notifier)
        .deleteAccount(password: 'secret');

    expect(success, false);
    expect(notifier.requestCount, 0);
    expect(notifier.didClearSession, false);
  });
}

class _DeleteNotifier extends CloudAccountNotifier {
  final CloudAccountState initialState;
  final Object? requestError;
  final Object? logoutError;
  final Completer<void>? logoutCompleter;
  final String? cleanupError;
  var requestCount = 0;
  var didClearSession = false;

  _DeleteNotifier({
    this.initialState = const CloudAccountState(isLoggedIn: true),
    this.requestError,
    this.logoutError,
    this.logoutCompleter,
    this.cleanupError,
  });

  @override
  CloudAccountState build() => initialState;

  @override
  Future<void> Function({required String password, String? twoFactorCode})
  get deleteAccountRequest =>
      ({required String password, String? twoFactorCode}) async {
        requestCount++;
        if (requestError != null) throw requestError!;
      };

  @override
  Future<void> Function() get logoutRequest => () async {
    if (logoutError != null) throw logoutError!;
    await logoutCompleter?.future;
  };

  @override
  Future<String?> clearSession() async {
    didClearSession = true;
    state = const CloudAccountState();
    return cleanupError;
  }
}
