import 'dart:convert';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/controller.dart';
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/cloud_account_provider.g.dart';

class CloudAccountState {
  final CloudCredentials? credentials;
  final CloudProfile? profile;
  final CloudConfigInfo? configInfo;
  final CloudNotification? latestNotification;
  final bool isLoading;
  final String? error;
  final DateTime? lastRefreshTime;
  
  const CloudAccountState({
    this.credentials,
    this.profile,
    this.configInfo,
    this.latestNotification,
    this.isLoading = false,
    this.error,
    this.lastRefreshTime,
  });
  
  bool get isLoggedIn => credentials != null && !credentials!.isExpired;
  
  CloudAccountState copyWith({
    CloudCredentials? credentials,
    CloudProfile? profile,
    CloudConfigInfo? configInfo,
    CloudNotification? latestNotification,
    bool? isLoading,
    String? error,
    DateTime? lastRefreshTime,
  }) {
    return CloudAccountState(
      credentials: credentials ?? this.credentials,
      profile: profile ?? this.profile,
      configInfo: configInfo ?? this.configInfo,
      latestNotification: latestNotification ?? this.latestNotification,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      lastRefreshTime: lastRefreshTime ?? this.lastRefreshTime,
    );
  }
  
  CloudAccountState setLoading(bool loading) => copyWith(isLoading: loading, error: null);
}

@Riverpod(keepAlive: true)
class CloudAccount extends _$CloudAccount {
  static const _prefixKey = 'cloud_service_';
  static const _keyCredentials = '${_prefixKey}credentials';
  static const _keyConfigParams = '${_prefixKey}config_params';
  static const _keyBackupConfigParams = '${_prefixKey}backup_config_params';
  static const _keyLogoutFlag = '${_prefixKey}logout_flag';
  static const _keyProfile = '${_prefixKey}profile';
  static const _keyNotification = '${_prefixKey}notification';
  static const _configLabel = 'oixCloud';
  
  final _api = CloudApiService();
  bool _isInitialized = false;
  bool _isRefreshing = false;
  bool _isSyncingProfile = false;
  
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
      commonPrint.log('Failed to parse cached data: $e', logLevel: LogLevel.warning);
      return null;
    }
  }
  
  Future<Map<String, String>?> getSavedParams() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final json = prefs?.getString(_keyConfigParams);
    if (json == null || json.isEmpty) return null;
    try {
      return Map<String, String>.from(jsonDecode(json) as Map);
    } catch (e) {
      commonPrint.log('Failed to parse saved params: $e', logLevel: LogLevel.warning);
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
      await prefs?.setString(_keyNotification, jsonEncode(notification.toMap()));
    }
  }
  
  Future<({CloudProfile profile, CloudConfigInfo configInfo, CloudNotification? notification})>
      _fetchCloudData(String token, {Map<String, String>? extraParams}) async {
    final profile = await _api.fetchUserProfile(token);
    final (configInfo, notification) = await (
      _api.fetchConfigUrl(token: token, extraParams: extraParams),
      _api.fetchAnnouncement(),
    ).wait;
    return (profile: profile, configInfo: configInfo, notification: notification);
  }
  
  bool _isTokenExpiredError(Object error) {
    final s = error.toString();
    return s.contains('Invalid or expired access_token') ||
        (s.contains('expired') && s.contains('token'));
  }
  
  Profile? _findCloudProfile() {
    return ref.read(profilesProvider).cast<Profile?>().firstWhere(
      (p) => p?.isOixCloud == true,
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
      
      state = state.copyWith(
        credentials: credentials,
        profile: _decodeCached(prefs?.getString(_keyProfile), CloudProfile.fromApiResponse),
        latestNotification: _decodeCached(prefs?.getString(_keyNotification), CloudNotification.fromApiResponse),
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
    await _signIn(() => _api.loginWithPassword(email: email, password: password));
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
  
  Future<void> _handleLoginSuccess(CloudCredentials credentials) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setString(_keyCredentials, jsonEncode(credentials.toMap()));
      await prefs?.remove(_keyLogoutFlag);
      
      state = state.copyWith(credentials: credentials);
      
      final token = credentials.accessToken;
      final profile = await _api.fetchUserProfile(token);
      
      final savedParams = await getSavedParams();
      final hasSavedParams = prefs?.containsKey(_keyConfigParams) ?? false;
      
      Map<String, String>? extraParams = savedParams;
      
      if (!hasSavedParams && 
          profile.subscription.isNotEmpty && 
          profile.subscription != 'Pass Iron' && 
          profile.subscription != 'null') {
        final defaultParams = <String, String>{};
        if (profile.subscription == 'Pass Bronze') {
          defaultParams['lv'] = '2';
        } else {
          defaultParams['type'] = 'love';
        }
        
        if (defaultParams.isNotEmpty) {
          await prefs?.setString(_keyConfigParams, jsonEncode(defaultParams));
        } else {
          await prefs?.remove(_keyConfigParams);
        }
        extraParams = defaultParams;
      }
      
      final data = await _fetchCloudData(
        token,
        extraParams: extraParams?.isNotEmpty == true ? extraParams : null,
      );
      await _persistCloudData(profile: data.profile, notification: data.notification);
      
      state = state.copyWith(
        profile: data.profile,
        configInfo: data.configInfo,
        latestNotification: data.notification,
        isLoading: false,
        lastRefreshTime: DateTime.now(),
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
    if (_isRefreshing) return;
    _isRefreshing = true;
    
    try {
      final token = state.credentials!.accessToken;
      final savedParams = await getSavedParams();
      
      final data = await _fetchCloudData(token, extraParams: savedParams);
      await _persistCloudData(profile: data.profile, notification: data.notification);
      
      state = state.copyWith(
        profile: data.profile,
        configInfo: data.configInfo,
        latestNotification: data.notification,
        lastRefreshTime: DateTime.now(),
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
        commonPrint.log('Non-auth refresh error, keeping session: $error', logLevel: LogLevel.warning);
      }
    } finally {
      _isRefreshing = false;
    }
  }
  
  Future<void> refreshProfile({bool force = false}) async {
    if (!state.isLoggedIn) return;
    
    if (!force && state.lastRefreshTime != null) {
      final now = DateTime.now();
      if (now.difference(state.lastRefreshTime!).inMinutes < 30) {
        return;
      }
    }
    
    state = state.setLoading(true);
    try {
      await _refreshData();
      
      if (_findCloudProfile() == null && state.configInfo != null) {
        await _syncProfileConfig();
      }
    } finally {
      state = state.setLoading(false);
    }
  }
  
  Future<void> _syncProfileConfig() async {
    if (_isSyncingProfile) return;
    _isSyncingProfile = true;
    try {
      final configInfo = state.configInfo;
      if (configInfo == null) return;
    
      final cloudProfiles = ref.read(profilesProvider).where((p) => p.isOixCloud).toList();
      Profile? existing;
      
      if (cloudProfiles.isNotEmpty) {
        existing = cloudProfiles.first;
        for (int i = 1; i < cloudProfiles.length; i++) {
          await appController.deleteProfile(cloudProfiles[i].id);
        }
      }
      
      final profile = (existing ?? Profile.normal()).copyWith(
        url: configInfo.downloadUrl,
        label: _configLabel,
        autoUpdate: existing?.autoUpdate ?? true,
        autoUpdateDuration: existing?.autoUpdateDuration ?? const Duration(hours: 24),
      );
      
      appController.putProfile(profile);
      ref.read(currentProfileIdProvider.notifier).value = profile.id;
      
      try {
        await appController.updateProfile(profile);
        appController.applyProfileDebounce();
      } catch (e) {
        appController.putProfile(profile);
        rethrow;
      }
    } catch (error) {
      commonPrint.log('Sync profile failed: $error', logLevel: LogLevel.error);
      rethrow;
    } finally {
      _isSyncingProfile = false;
    }
  }
  
  Future<void> saveParamsAndSync(Map<String, String>? params) async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (params != null) {
      await prefs?.setString(_keyConfigParams, jsonEncode(params));
    } else {
      await prefs?.remove(_keyConfigParams);
    }
    
    final configInfo = await _api.fetchConfigUrl(
      token: state.credentials!.accessToken,
      extraParams: params?.isNotEmpty == true ? params : null,
    );
    state = state.copyWith(configInfo: configInfo);
    await _syncProfileConfig();
  }
  
  Future<void> updateConfigParams(Map<String, String> params) async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    
    final mergedParams = (await getSavedParams()) ?? <String, String>{};
    mergedParams.addAll(params);
    await saveParamsAndSync(mergedParams);
  }
  
  Future<void> removeConfigParam(String key) async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    
    try {
      final savedParams = await getSavedParams();
      if (savedParams == null) return;
      
      savedParams.remove(key);
      await saveParamsAndSync(savedParams);
    } catch (e) {
      commonPrint.log('Failed to remove param: $e', logLevel: LogLevel.warning);
    }
  }
  
  Future<void> clearConfigParams() async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    await saveParamsAndSync(null);
  }
  
  Future<void> setConfigParams(Map<String, String> params) async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    await saveParamsAndSync(params);
  }
  
  Future<void> saveAndEnableOverseasNetwork() async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    
    final prefs = await preferences.sharedPreferencesCompleter.future;
    try {
      // 备份当前参数
      final currentParams = await getSavedParams();
      if (currentParams != null) {
        await prefs?.setString(_keyBackupConfigParams, jsonEncode(currentParams));
      }
      
      // 清空参数，只保留海外网络标记
      await saveParamsAndSync({'lv': '1'});
    } catch (e) {
      commonPrint.log('Failed to enable overseas network: $e', logLevel: LogLevel.warning);
    }
  }
  
  Future<void> disableOverseasNetwork() async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    
    final prefs = await preferences.sharedPreferencesCompleter.future;
    try {
      // 恢复备份的参数
      final backupJson = prefs?.getString(_keyBackupConfigParams);
      if (backupJson != null && backupJson.isNotEmpty) {
        try {
          final backupParams = Map<String, String>.from(jsonDecode(backupJson) as Map);
          await saveParamsAndSync(backupParams);
        } catch (e) {
          commonPrint.log('Failed to parse backup params: $e', logLevel: LogLevel.warning);
          // 如果备份参数损坏，则清空所有参数
          await saveParamsAndSync(null);
        }
      } else {
        // 没有备份参数，清空所有参数
        await saveParamsAndSync(null);
      }
    } catch (e) {
      commonPrint.log('Failed to disable overseas network: $e', logLevel: LogLevel.warning);
    }
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
          prefs.remove(_keyBackupConfigParams),
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
      final cloudProfiles = ref.read(profilesProvider).where(
        (p) => p.isOixCloud || p.label == state.configInfo?.profileName,
      );
      
      for (final profile in cloudProfiles) {
        await appController.deleteProfile(profile.id);
      }
    } catch (error) {
      commonPrint.log('Remove profile error: $error', logLevel: LogLevel.warning);
    }
  }
}
