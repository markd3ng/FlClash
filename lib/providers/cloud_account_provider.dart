import 'dart:convert';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/cloud_account_provider.g.dart';

class CloudAccountState {
  final CloudCredentials? credentials;
  final CloudProfile? profile;
  final CloudConfigInfo? configInfo;
  final CloudNotification? latestNotification;
  final Map<String, String>? configParams;
  final bool isLoading;
  final String? error;

  const CloudAccountState({
    this.credentials,
    this.profile,
    this.configInfo,
    this.latestNotification,
    this.configParams,
    this.isLoading = false,
    this.error,
  });

  bool get isLoggedIn => credentials != null && !credentials!.isExpired;

  CloudAccountState copyWith({
    CloudCredentials? credentials,
    CloudProfile? profile,
    CloudConfigInfo? configInfo,
    CloudNotification? latestNotification,
    Map<String, String>? configParams,
    bool? isLoading,
    String? error,
  }) {
    return CloudAccountState(
      credentials: credentials ?? this.credentials,
      profile: profile ?? this.profile,
      configInfo: configInfo ?? this.configInfo,
      latestNotification: latestNotification ?? this.latestNotification,
      configParams: configParams ?? this.configParams,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  CloudAccountState setLoading(bool loading) =>
      copyWith(isLoading: loading, error: null);
}

@Riverpod(keepAlive: true)
class CloudAccount extends _$CloudAccount {
  static const _prefixKey = 'cloud_service_';
  static const _keyCredentials = '${_prefixKey}credentials';
  static const _keyConfigParams = '${_prefixKey}config_params';
  static const _keyLogoutFlag = '${_prefixKey}logout_flag';
  static const _keyProfile = '${_prefixKey}profile';
  static const _keyNotification = '${_prefixKey}notification';
  static const _configLabel = 'oixCloud';

  final _api = CloudApiService();
  bool _isInitialized = false;
  DateTime? _lastRefreshTime;

  @override
  CloudAccountState build() {
    _autoRestore();
    return const CloudAccountState();
  }

  T? _decodeCached<T>(String? json, T Function(Map<String, dynamic>) factory) {
    if (json == null) return null;
    try {
      return factory(Map<String, dynamic>.from(jsonDecode(json) as Map));
    } catch (e) {
      commonPrint.log(
        'Failed to parse cached data: $e',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<Map<String, String>?> _loadSavedParams() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final json = prefs?.getString(_keyConfigParams);
    if (json == null || json.isEmpty) return null;
    try {
      return Map<String, String>.from(jsonDecode(json) as Map);
    } catch (e) {
      commonPrint.log(
        'Failed to parse saved params: $e',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> _persistCloudData({
    required CloudProfile profile,
    CloudNotification? notification,
  }) async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setString(_keyProfile, jsonEncode(profile.toMap()));
    if (notification != null) {
      await prefs?.setString(
        _keyNotification,
        jsonEncode(notification.toMap()),
      );
    }
  }

  Future<({CloudConfigInfo configInfo, CloudNotification? notification})>
  _fetchConfigAndNotification(
    String token, {
    Map<String, String>? extraParams,
  }) async {
    final (configInfo, notification) = await (
      _api.fetchConfigUrl(token: token, extraParams: extraParams),
      _api.fetchAnnouncement(),
    ).wait;
    return (configInfo: configInfo, notification: notification);
  }

  bool _isTokenExpiredError(Object error) {
    final s = error.toString();
    return s.contains('Invalid or expired access_token') ||
        (s.contains('expired') && s.contains('token'));
  }

  Profile? _findCloudProfile() {
    return globalState.config.profiles.cast<Profile?>().firstWhere(
      (p) => p?.label?.contains(_configLabel) ?? false,
      orElse: () => null,
    );
  }

  Future<void> _autoRestore() async {
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;

      if (prefs?.getBool(_keyLogoutFlag) ?? false) return;

      final credentialsJson = prefs?.getString(_keyCredentials);
      if (credentialsJson == null) return;

      final credentials = CloudCredentials.fromMap(
        Map<String, dynamic>.from(jsonDecode(credentialsJson) as Map),
      );
      if (credentials.isExpired) return;

      final savedParams = await _loadSavedParams();
      state = state.copyWith(
        credentials: credentials,
        profile: _decodeCached(
          prefs?.getString(_keyProfile),
          CloudProfile.fromApiResponse,
        ),
        latestNotification: _decodeCached(
          prefs?.getString(_keyNotification),
          CloudNotification.fromApiResponse,
        ),
        configParams: savedParams ?? <String, String>{},
      );
      await _refreshData();
    } catch (e) {
      commonPrint.log('Auto restore failed: $e', logLevel: LogLevel.warning);
    }
  }

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    await _signIn(
      () => _api.loginWithPassword(email: email, password: password),
    );
  }

  Future<void> signInWithToken(String token) async {
    await _signIn(() => _api.loginWithToken(token));
  }

  Future<void> _signIn(Future<CloudCredentials> Function() authenticate) async {
    state = state.setLoading(true);
    try {
      final credentials = await authenticate();
      await _handleLoginSuccess(credentials);
    } catch (error) {
      state = state.copyWith(isLoading: false, error: error.toString());
      rethrow;
    }
  }

  void _applyDefaultLevelParams(CloudProfile profile, Map<String, String> params) {
    if (profile.level >= 3) {
      params['type'] = 'love';
    } else if (profile.level == 2) {
      params['lv'] = '2';
    }
  }

  Future<void> _handleLoginSuccess(CloudCredentials credentials) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setString(_keyCredentials, jsonEncode(credentials.toMap()));
      await prefs?.remove(_keyLogoutFlag);

      state = state.copyWith(credentials: credentials);

      final token = credentials.accessToken;
      final profile = await _api.fetchUserProfile(token);

      final params = <String, String>{};
      _applyDefaultLevelParams(profile, params);

      await _saveConfigParamsToPrefs(params);

      final data = await _fetchConfigAndNotification(
        token,
        extraParams: params.isNotEmpty ? params : null,
      );
      await _persistCloudData(
        profile: profile,
        notification: data.notification,
      );

      state = state.copyWith(
        profile: profile,
        configInfo: data.configInfo,
        latestNotification: data.notification,
        configParams: params.isNotEmpty ? params : <String, String>{},
        isLoading: false,
      );

      await _syncProfileConfig();
    } catch (e) {
      final l10n = AppLocalizations.current;
      state = state.copyWith(
        isLoading: false,
        error: '${l10n.configDownloadFailed}: $e',
      );
      globalState.showMessage(
        title: l10n.warning,
        message: TextSpan(text: '${l10n.loginSuccessConfigFailed}：\n$e'),
      );
    }
  }

  Future<void> _refreshData() async {
    if (!state.isLoggedIn) return;

    try {
      final token = state.credentials!.accessToken;
      var savedParams = await _loadSavedParams();

      final profile = await _api.fetchUserProfile(token);
      
      final currentParams = savedParams ?? <String, String>{};
      final isOverseasEnabled = currentParams['lv'] == '1';
      currentParams.remove('type');
      currentParams.remove('lv');
      
      if (profile.level >= 2 && isOverseasEnabled) {
        currentParams['lv'] = '1';
      } else {
        _applyDefaultLevelParams(profile, currentParams);
      }
      
      savedParams = currentParams;
      await _saveConfigParamsToPrefs(savedParams);

      final data = await _fetchConfigAndNotification(
        token,
        extraParams: savedParams.isNotEmpty ? savedParams : null,
      );
      await _persistCloudData(
        profile: profile,
        notification: data.notification,
      );

      state = state.copyWith(
        profile: profile,
        configInfo: data.configInfo,
        latestNotification: data.notification,
        configParams: savedParams ?? <String, String>{},
      );

      await _syncProfileConfig();
    } catch (error) {
      commonPrint.log('Refresh failed: $error', logLevel: LogLevel.error);

      if (error is NoPlanException) {
        final l10n = AppLocalizations.current;
        await signOut(revokeToken: true);
        globalState.showMessage(
          title: l10n.noPlanSubscription,
          message: TextSpan(text: l10n.accountNoPlan),
        );
      } else if (_isTokenExpiredError(error)) {
        final l10n = AppLocalizations.current;
        await signOut(revokeToken: true);
        globalState.showMessage(
          title: l10n.loginExpired,
          message: TextSpan(text: l10n.tokenExpired),
        );
      } else {
        commonPrint.log(
          'Non-auth refresh error, keeping session: $error',
          logLevel: LogLevel.warning,
        );
      }
    }
  }

  Future<void> refreshProfile({bool force = false}) async {
    if (!state.isLoggedIn || state.isLoading) return;

    if (!force && _lastRefreshTime != null) {
      if (DateTime.now().difference(_lastRefreshTime!) < const Duration(minutes: 30)) {
        return;
      }
    }

    state = state.setLoading(true);
    try {
      await _refreshData();

      if (_findCloudProfile() == null && state.configInfo != null) {
        await _syncProfileConfig();
      }
      _lastRefreshTime = DateTime.now();
    } finally {
      state = state.setLoading(false);
    }
  }

  Future<void> _syncProfileConfig() async {
    final configInfo = state.configInfo;
    if (configInfo == null) return;

    try {
      final existing = _findCloudProfile();

      final profile = (existing ?? Profile.normal()).copyWith(
        url: configInfo.downloadUrl,
        label: _configLabel,
        autoUpdate: true,
        autoUpdateDuration: const Duration(hours: 24),
        isUpdating: true,
      );

      globalState.appController.setProfile(profile);
      ref.read(currentProfileIdProvider.notifier).value = profile.id;

      try {
        await globalState.appController.updateProfile(profile);
        globalState.appController.handleChangeProfile();
      } catch (e) {
        globalState.appController.setProfile(
          profile.copyWith(isUpdating: false),
        );
        rethrow;
      }
    } catch (error) {
      commonPrint.log('Sync profile failed: $error', logLevel: LogLevel.error);
      rethrow;
    }
  }

  Future<void> _saveConfigParamsToPrefs(Map<String, String>? params) async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (params != null && params.isNotEmpty) {
      await prefs?.setString(_keyConfigParams, jsonEncode(params));
    } else {
      await prefs?.remove(_keyConfigParams);
    }
  }

  Future<void> _saveParamsAndSync(Map<String, String>? params) async {
    await _saveConfigParamsToPrefs(params);

    final configInfo = await _api.fetchConfigUrl(
      token: state.credentials!.accessToken,
      extraParams: params,
    );
    
    state = state.copyWith(
      configInfo: configInfo,
      configParams: params ?? <String, String>{},
    );
    await _syncProfileConfig();
  }

  Future<void> setOverseasOption(bool isOverseas) async {
    if (!state.isLoggedIn || state.profile == null || state.isLoading) return;

    state = state.setLoading(true);
    try {
      final level = state.profile!.level;
      if (level < 2) return;

      final params = (await _loadSavedParams()) ?? <String, String>{};
      params.remove('type');
      params.remove('lv');

      if (isOverseas) {
        params['lv'] = '1';
      } else {
        _applyDefaultLevelParams(state.profile!, params);
      }

      await _saveParamsAndSync(params);
    } finally {
      state = state.setLoading(false);
    }
  }

  Future<void> updateConfigParams(Map<String, String> params) async {
    if (!state.isLoggedIn || state.configInfo == null) return;

    final mergedParams = (await _loadSavedParams()) ?? <String, String>{};
    mergedParams.addAll(params);
    await _saveParamsAndSync(mergedParams);
  }

  Future<void> removeConfigParam(String key) async {
    if (!state.isLoggedIn || state.configInfo == null) return;

    try {
      final savedParams = await _loadSavedParams();
      if (savedParams == null) return;

      savedParams.remove(key);
      await _saveParamsAndSync(savedParams);
    } catch (e) {
      commonPrint.log('Failed to remove param: $e', logLevel: LogLevel.warning);
    }
  }

  Future<void> clearConfigParams() async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    await _saveParamsAndSync(null);
  }

  Future<void> signOut({bool revokeToken = false}) async {
    try {
      if (revokeToken && state.credentials != null) {
        await _api.logout(state.credentials!.accessToken);
      }
      await _removeProfileConfig();

      final prefs = await preferences.sharedPreferencesCompleter.future;
      await Future.wait([
        if (prefs != null) ...[
          prefs.remove(_keyCredentials),
          prefs.remove(_keyConfigParams),
          prefs.remove(_keyProfile),
          prefs.remove(_keyNotification),
          prefs.setBool(_keyLogoutFlag, true),
        ],
      ]);
    } catch (error) {
      commonPrint.log('Sign out error: $error', logLevel: LogLevel.warning);
    } finally {
      state = const CloudAccountState();
    }
  }

  Future<void> _removeProfileConfig() async {
    try {
      final cloudProfiles = globalState.config.profiles.where(
        (p) =>
            (p.label?.contains(_configLabel) ?? false) ||
            p.label == state.configInfo?.profileName,
      );

      for (final profile in cloudProfiles) {
        await globalState.appController.deleteProfile(profile.id);
      }
    } catch (error) {
      commonPrint.log(
        'Remove profile error: $error',
        logLevel: LogLevel.warning,
      );
    }
  }
}
