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
  static const _keyProfile = '${_prefixKey}profile';
  static const _keyNotification = '${_prefixKey}notification';
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
        CloudProfile? cachedProfile;
        CloudNotification? cachedNotification;
        
        final profileJson = prefs?.getString(_keyProfile);
        if (profileJson != null) {
          try {
            cachedProfile = CloudProfile.fromApiResponse(
              Map<String, dynamic>.from(jsonDecode(profileJson) as Map),
            );
          } catch (e) {
            commonPrint.log('Failed to parse cached profile: $e', logLevel: LogLevel.warning);
          }
        }
        
        final notificationJson = prefs?.getString(_keyNotification);
        if (notificationJson != null) {
          try {
            cachedNotification = CloudNotification.fromApiResponse(
              Map<String, dynamic>.from(jsonDecode(notificationJson) as Map),
            );
          } catch (e) {
            commonPrint.log('Failed to parse cached notification: $e', logLevel: LogLevel.warning);
          }
        }
        
        state = state.copyWith(
          credentials: credentials,
          profile: cachedProfile,
          latestNotification: cachedNotification,
        );
        await _refreshData();
      }
    } catch (e) {
      commonPrint.log('Auto restore failed: $e', logLevel: LogLevel.warning);
      await signOut(revokeToken: false);
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
      
      final token = credentials.accessToken;
      final profile = await _api.fetchUserProfile(token);
      
      final params = <String, String>{};
      if (profile.subscription.isNotEmpty && profile.subscription != 'Pass Iron') {
        params['type'] = 'love';
      }
      
      if (params.isNotEmpty) {
        await prefs?.setString(_keyConfigParams, jsonEncode(params));
      }
      
      final (configInfo, notification) = await (
        _api.fetchConfigUrl(token: token, extraParams: params.isNotEmpty ? params : null),
        _api.fetchAnnouncement(),
      ).wait;
      
      await prefs?.setString(_keyProfile, jsonEncode(profile.toMap()));
      if (notification != null) {
        await prefs?.setString(_keyNotification, jsonEncode(notification.toMap()));
      }
      
      state = state.copyWith(
        profile: profile,
        configInfo: configInfo,
        latestNotification: notification,
        isLoading: false,
      );
      
      await _syncProfileConfig();
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
      final prefs = await preferences.sharedPreferencesCompleter.future;
      
      final profile = await _api.fetchUserProfile(token);
      
      Map<String, String>? savedParams;
      final savedParamsJson = prefs?.getString(_keyConfigParams);
      if (savedParamsJson != null && savedParamsJson.isNotEmpty) {
        try {
          savedParams = Map<String, String>.from(jsonDecode(savedParamsJson) as Map);
        } catch (e) {
          commonPrint.log('Failed to parse saved params: $e', logLevel: LogLevel.warning);
        }
      }
      
      final (configInfo, notification) = await (
        _api.fetchConfigUrl(token: token, extraParams: savedParams),
        _api.fetchAnnouncement(),
      ).wait;
      
      await prefs?.setString(_keyProfile, jsonEncode(profile.toMap()));
      if (notification != null) {
        await prefs?.setString(_keyNotification, jsonEncode(notification.toMap()));
      }
      
      state = state.copyWith(
        profile: profile,
        configInfo: configInfo,
        latestNotification: notification,
      );
      
      await _syncProfileConfig();
    } catch (error) {
      commonPrint.log('Refresh failed: $error', logLevel: LogLevel.error);
      
      if (error is NoPlanException) {
        final appLocalizations = AppLocalizations.current;
        await signOut(revokeToken: true);
        globalState.showMessage(
          title: appLocalizations.noPlanSubscription,
          message: TextSpan(text: appLocalizations.accountNoPlan),
        );
      } else {
        final errorStr = error.toString();
        if (errorStr.contains('Invalid or expired access_token')) {
          final appLocalizations = AppLocalizations.current;
          await signOut(revokeToken: true);
          globalState.showMessage(
            title: appLocalizations.loginExpired,
            message: TextSpan(text: appLocalizations.tokenExpired),
          );
        } else {
          rethrow;
        }
      }
    }
  }
  
  Future<void> refreshProfile() async {
    if (!state.isLoggedIn) return;
    
    state = state.setLoading(true);
    try {
      await _refreshData();
      
      final hasDlerCloudProfile = globalState.config.profiles.any(
        (p) => p.label?.contains(_configLabel) ?? false,
      );
      
      if (!hasDlerCloudProfile && state.configInfo != null) {
        await _syncProfileConfig();
      }
    } finally {
      state = state.setLoading(false);
    }
  }
  
  Future<void> _syncProfileConfig() async {
    final configInfo = state.configInfo;
    if (configInfo == null) return;
    
    try {
      final existingProfile = globalState.config.profiles.cast<Profile?>().firstWhere(
        (p) => p?.label?.contains(_configLabel) ?? false,
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
    if (!state.isLoggedIn || state.configInfo == null) return;
    
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final mergedParams = <String, String>{};
    
    final savedParamsJson = prefs?.getString(_keyConfigParams);
    if (savedParamsJson != null && savedParamsJson.isNotEmpty) {
      try {
        mergedParams.addAll(Map<String, String>.from(jsonDecode(savedParamsJson) as Map));
      } catch (_) {}
    }
    
    mergedParams.addAll(params);
    await prefs?.setString(_keyConfigParams, jsonEncode(mergedParams));
    
    final token = state.credentials!.accessToken;
    final configInfo = await _api.fetchConfigUrl(
      token: token,
      extraParams: mergedParams,
    );
    
    state = state.copyWith(configInfo: configInfo);
    await _syncProfileConfig();
  }
  
  Future<void> removeConfigParam(String key) async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final savedParamsJson = prefs?.getString(_keyConfigParams);
    if (savedParamsJson == null || savedParamsJson.isEmpty) return;
    
    try {
      final savedParams = Map<String, String>.from(jsonDecode(savedParamsJson) as Map);
      savedParams.remove(key);
      
      if (savedParams.isNotEmpty) {
        await prefs?.setString(_keyConfigParams, jsonEncode(savedParams));
      } else {
        await prefs?.remove(_keyConfigParams);
      }
      
      final token = state.credentials!.accessToken;
      final configInfo = await _api.fetchConfigUrl(
        token: token,
        extraParams: savedParams.isNotEmpty ? savedParams : null,
      );
      
      state = state.copyWith(configInfo: configInfo);
      await _syncProfileConfig();
    } catch (e) {
      commonPrint.log('Failed to remove param: $e', logLevel: LogLevel.warning);
    }
  }
  
  Future<void> clearConfigParams() async {
    if (!state.isLoggedIn || state.configInfo == null) return;
    
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.remove(_keyConfigParams);
    
    final configInfo = await _api.fetchConfigUrl(token: state.credentials!.accessToken);
    state = state.copyWith(configInfo: configInfo);
    await _syncProfileConfig();
  }
  
  Future<void> signOut({bool revokeToken = false}) async {
    try {
      if (revokeToken && state.credentials != null) {
        await _api.logout(state.credentials!.accessToken);
      }
      
      await _removeProfileConfig();
      
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.remove(_keyCredentials);
      await prefs?.remove(_keyConfigParams);
      await prefs?.remove(_keyProfile);
      await prefs?.remove(_keyNotification);
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
        (p) => (p.label?.contains(_configLabel) ?? false) || p.label == state.configInfo?.profileName,
      ).toList();
      
      for (final profile in cloudProfile) {
        await globalState.appController.deleteProfile(profile.id);
      }
    } catch (error) {
      commonPrint.log('Remove profile error: $error', logLevel: LogLevel.warning);
    }
  }
}
