import 'dart:convert';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/cloud_account_provider.g.dart';

class CloudAccountState {
  final CloudCredentials? credentials;
  final CloudProfile? profile;
  final CloudConfigInfo? configInfo;
  final CloudNotification? latestNotification;
  final bool isLoading;
  final String? error;
  
  const CloudAccountState({
    this.credentials,
    this.profile,
    this.configInfo,
    this.latestNotification,
    this.isLoading = false,
    this.error,
  });
  
  bool get isLoggedIn => credentials != null && !credentials!.isExpired;
  bool get hasValidProfile => profile != null;
  
  CloudAccountState copyWith({
    CloudCredentials? credentials,
    CloudProfile? profile,
    CloudConfigInfo? configInfo,
    CloudNotification? latestNotification,
    bool? isLoading,
    String? error,
  }) {
    return CloudAccountState(
      credentials: credentials ?? this.credentials,
      profile: profile ?? this.profile,
      configInfo: configInfo ?? this.configInfo,
      latestNotification: latestNotification ?? this.latestNotification,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
  
  CloudAccountState clearError() => copyWith(error: null);
  
  CloudAccountState setLoading(bool loading) => copyWith(isLoading: loading, error: null);
}

@Riverpod(keepAlive: true)
class CloudAccount extends _$CloudAccount {
  static const _prefixKey = 'cloud_service_';
  static const _keyCredentials = '${_prefixKey}credentials';
  static const _keyConfigParams = '${_prefixKey}config_params';
  static const _keyLogoutFlag = '${_prefixKey}logout_flag';
  static const _configLabel = 'Dler Cloud';
  
  final _api = CloudApiService();
  bool _isInitialized = false;
  
  @override
  CloudAccountState build() {
    _autoRestore();
    return const CloudAccountState();
  }
  
  Future<void> _autoRestore() async {
    if (_isInitialized) return;
    _isInitialized = true;
    
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      
      final wasLoggedOut = prefs?.getBool(_keyLogoutFlag) ?? false;
      if (wasLoggedOut) return;
      
      final credentialsMap = prefs?.getString(_keyCredentials);
      if (credentialsMap == null) return;
      
      final credentials = CloudCredentials.fromMap(
        Map<String, dynamic>.from(jsonDecode(credentialsMap) as Map),
      );
      
      if (!credentials.isExpired) {
        state = state.copyWith(credentials: credentials);
        await _refreshData();
      }
    } catch (e) {
      commonPrint.log('Auto restore failed: $e', logLevel: LogLevel.warning);
      await signOut(deleteCredentials: false);
    }
  }
  
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    state = state.setLoading(true);
    
    try {
      final credentials = await _api.loginWithPassword(
        email: email,
        password: password,
      );
      
      await _handleLoginSuccess(credentials);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: error.toString(),
      );
      rethrow;
    }
  }
  
  Future<void> signInWithToken(String token) async {
    state = state.setLoading(true);
    
    try {
      final credentials = await _api.loginWithToken(token);
      await _handleLoginSuccess(credentials);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: error.toString(),
      );
      rethrow;
    }
  }
  
  Future<void> _handleLoginSuccess(CloudCredentials credentials) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setString(_keyCredentials, jsonEncode(credentials.toMap()));
      await prefs?.remove(_keyLogoutFlag);
      
      state = state.copyWith(credentials: credentials);
      
      await _refreshData();
      state = state.setLoading(false);
    } catch (e) {
      final appLocalizations = AppLocalizations.current;
      state = state.copyWith(
        isLoading: false,
        error: '${appLocalizations.configDownloadFailed}: ${e.toString()}',
      );
      globalState.showMessage(
        title: appLocalizations.warning,
        message: TextSpan(text: '${appLocalizations.loginSuccessConfigFailed}：\n${e.toString()}'),
      );
    }
  }
  
  Future<void> _refreshData() async {
    if (!state.isLoggedIn) return;
    
    try {
      final token = state.credentials!.accessToken;
      final (profile, configInfo, notification) = await (
        _api.fetchUserProfile(token),
        _api.fetchConfigUrl(token: token),
        _api.fetchAnnouncement(),
      ).wait;
      
      state = state.copyWith(
        profile: profile,
        configInfo: configInfo,
        latestNotification: notification,
      );
      
      await _syncProfileConfig();
    } catch (error) {
      commonPrint.log('Refresh failed: $error', logLevel: LogLevel.error);
      
      final errorStr = error.toString();
      if (errorStr.contains('Invalid or expired access_token')) {
        final appLocalizations = AppLocalizations.current;
        await signOut(deleteCredentials: true);
        globalState.showMessage(
          title: appLocalizations.loginExpired,
          message: TextSpan(text: appLocalizations.tokenExpired),
        );
      } else {
        rethrow;
      }
    }
  }
  
  Future<void> refreshProfile() async {
    if (!state.isLoggedIn) return;
    
    state = state.setLoading(true);
    try {
      await _refreshData();
    } finally {
      state = state.setLoading(false);
    }
  }
  
  Future<void> _syncProfileConfig() async {
    final configInfo = state.configInfo;
    if (configInfo == null) return;
    
    try {
      final profiles = globalState.config.profiles;
      
      final existingProfile = profiles.cast<Profile?>().firstWhere(
        (p) => p?.label == _configLabel,
        orElse: () => null,
      );
      
      final profile = (existingProfile ?? Profile(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        label: _configLabel,
        url: configInfo.fullUrl,
        autoUpdate: true,
        autoUpdateDuration: const Duration(hours: 24),
      )).copyWith(
        url: configInfo.fullUrl,
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
        globalState.appController.setProfile(profile.copyWith(isUpdating: false));
        rethrow;
      }
    } catch (error) {
      commonPrint.log('Sync profile failed: $error', logLevel: LogLevel.error);
      rethrow;
    }
  }
  
  Future<void> updateConfigParams(Map<String, String> params) async {
    if (state.configInfo == null) return;
    
    state = state.copyWith(
      configInfo: state.configInfo!.withParams(params),
    );
    
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setString(_keyConfigParams, jsonEncode(params));
    
    await _syncProfileConfig();
  }
  
  Future<void> signOut({bool deleteCredentials = true}) async {
    try {
      if (state.credentials != null) {
        await _api.logout(state.credentials!.accessToken);
      }
      
      await _removeProfileConfig();
      
      final prefs = await preferences.sharedPreferencesCompleter.future;
      
      if (deleteCredentials) {
        await prefs?.remove(_keyCredentials);
        await prefs?.remove(_keyConfigParams);
      }
      
      await prefs?.setBool(_keyLogoutFlag, true);
      
      state = const CloudAccountState();
    } catch (error) {
      commonPrint.log('Sign out error: $error', logLevel: LogLevel.warning);
      state = const CloudAccountState();
    }
  }
  
  Future<void> _removeProfileConfig() async {
    try {
      final profiles = globalState.config.profiles;
      final cloudProfile = profiles.where(
        (p) => p.label == _configLabel || p.label == state.configInfo?.profileName,
      ).toList();
      
      for (final profile in cloudProfile) {
        await globalState.appController.deleteProfile(profile.id);
      }
    } catch (error) {
      commonPrint.log('Remove profile error: $error', logLevel: LogLevel.warning);
    }
  }
}
