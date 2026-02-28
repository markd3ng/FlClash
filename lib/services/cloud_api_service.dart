import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/cloud_account.dart';
import 'package:fl_clash/state.dart';

class CloudApiService {
  static final CloudApiService _instance = CloudApiService._internal();
  factory CloudApiService() => _instance;
  
  CloudApiService._internal() {
    _initializeClient();
  }
  
  static const _apiBase = 'https://oics.net/api/v1';
  static const _serviceCheckUrl = 'https://oics.net/check';
  static const _timeoutSeconds = 10;
  
  late final Dio _primaryClient;
  late final Dio _fallbackClient;
  
  void _initializeClient() {
    _primaryClient = Dio(BaseOptions(
      baseUrl: _apiBase,
      connectTimeout: const Duration(seconds: _timeoutSeconds),
      receiveTimeout: const Duration(seconds: _timeoutSeconds * 2),
      sendTimeout: const Duration(seconds: _timeoutSeconds),
      headers: {'User-Agent': appName},
    ));
    
    _fallbackClient = Dio(BaseOptions(
      baseUrl: _apiBase,
      connectTimeout: const Duration(seconds: _timeoutSeconds),
      receiveTimeout: const Duration(seconds: _timeoutSeconds * 2),
      sendTimeout: const Duration(seconds: _timeoutSeconds),
      headers: {'User-Agent': appName},
    ));
    
    _fallbackClient.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (uri) => FlClashHttpOverrides.handleFindProxy(uri);
        return client;
      },
    );
  }
  
  static const _endpoints = _ApiEndpoints();
  
  Future<Map<String, dynamic>> _request({
    required String endpoint,
    required Map<String, dynamic> payload,
    bool isLoginAttempt = false,
  }) async {
    try {
      final response = await _primaryClient.post(endpoint, data: payload);
      return _handleResponse(response);
    } on DioException catch (primaryError) {
      if (_shouldRetryWithProxy(primaryError)) {
        try {
          final response = await _fallbackClient.post(endpoint, data: payload);
          return _handleResponse(response);
        } on DioException catch (_) {
          throw _buildErrorMessage(primaryError, isLoginAttempt: isLoginAttempt);
        }
      }
      
      throw _buildErrorMessage(primaryError, isLoginAttempt: isLoginAttempt);
    }
  }
  
  bool _shouldRetryWithProxy(DioException error) {
    if (globalState.appState.runTime == null) return false;
    
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.receiveTimeout;
  }
  
  Map<String, dynamic> _handleResponse(Response response) {
    final appLocalizations = AppLocalizations.current;
    if (response.statusCode != HttpStatus.ok) {
      throw 'HTTP ${response.statusCode}: ${appLocalizations.serverError}';
    }
    
    final data = response.data as Map<String, dynamic>?;
    if (data == null) {
      throw appLocalizations.emptyResponse;
    }
    
    final statusCode = data['ret'] as int?;
    if (statusCode != 200) {
      final message = data['msg'] as String? ?? appLocalizations.unknownError;
      throw message;
    }
    
    return data;
  }
  
  String _buildErrorMessage(DioException error, {bool isLoginAttempt = false}) {
    final appLocalizations = AppLocalizations.current;
    String message = switch (error.type) {
      DioExceptionType.connectionTimeout => appLocalizations.connectionTimeout,
      DioExceptionType.sendTimeout => appLocalizations.sendTimeout,
      DioExceptionType.receiveTimeout => appLocalizations.receiveTimeout,
      DioExceptionType.badCertificate => appLocalizations.sslError,
      DioExceptionType.cancel => appLocalizations.requestCancelled,
      DioExceptionType.badResponse => 'HTTP ${error.response?.statusCode}',
      _ => appLocalizations.networkError,
    };
    
    if (isLoginAttempt && _isNetworkIssue(error)) {
      message += '\n${appLocalizations.checkNetworkConnection}';
    }
    
    return message;
  }
  
  bool _isNetworkIssue(DioException error) {
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.receiveTimeout;
  }
  
  Future<CloudCredentials> loginWithPassword({
    required String email,
    required String password,
  }) async {
    final response = await _request(
      endpoint: _endpoints.login,
      payload: {'email': email, 'passwd': password},
      isLoginAttempt: true,
    );
    
    final data = response['data'] as Map<String, dynamic>;
    return CloudCredentials(
      accessToken: data['token'] as String,
      tokenExpire: data['token_expire'] as String?,
    );
  }
  
  Future<CloudCredentials> loginWithToken(String token) async {
    await _request(
      endpoint: _endpoints.userInfo,
      payload: {'access_token': token},
      isLoginAttempt: true,
    );
    
    return CloudCredentials(accessToken: token);
  }
  
  Future<CloudProfile> fetchUserProfile(String token) async {
    final response = await _request(
      endpoint: _endpoints.userInfo,
      payload: {'access_token': token},
    );
    
    final data = response['data'] as Map<String, dynamic>;
    return CloudProfile.fromApiResponse(data);
  }
  
  Future<CloudConfigInfo> fetchConfigUrl({
    required String token,
    Map<String, String>? extraParams,
  }) async {
    final payload = <String, dynamic>{'access_token': token};
    
    if (extraParams != null && extraParams.isNotEmpty) {
      final paramsStr = extraParams.entries
          .map((e) => '${e.key}=${e.value}')
          .join('&');
      payload['optional_params'] = '&$paramsStr';
    }
    
    final response = await _request(
      endpoint: _endpoints.managedConfig,
      payload: payload,
    );
    
    return CloudConfigInfo.fromApiResponse(response);
  }
  
  Future<CloudNotification?> fetchAnnouncement() async {
    try {
      final response = await _primaryClient.get(_endpoints.announcement);
      final data = _handleResponse(response);
      
      return CloudNotification.fromApiResponse(
        data['data'] as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
  
  Future<String?> checkServiceHealth() async {
    try {
      final response = await _primaryClient.get(
        _serviceCheckUrl,
        options: Options(responseType: ResponseType.plain),
      );
      
      if (response.statusCode != HttpStatus.ok) return 'Service Check Failed';
      
      final content = response.data?.toString().trim() ?? '';
      return content == 'success' ? null : 'Service Check Failed';
    } on DioException catch (error) {
      if (_shouldRetryWithProxy(error)) {
        try {
          final response = await _fallbackClient.get(
            _serviceCheckUrl,
            options: Options(responseType: ResponseType.plain),
          );
          final content = response.data?.toString().trim() ?? '';
          return content == 'success' ? null : 'Service Check Failed';
        } catch (_) {}
      }
      return _buildErrorMessage(error);
    } catch (e) {
      return e.toString();
    }
  }
  
  Future<void> logout(String token) async {
    try {
      await _request(
        endpoint: _endpoints.logout,
        payload: {'access_token': token},
      );
    } catch (_) {}
  }
  
  Future<String?> fetchLatestVersion() async {
    try {
      final response = await _primaryClient.get(_endpoints.version);
      final data = _handleResponse(response);
      final versionData = data['data'];
      if (versionData is Map<String, dynamic>) {
        return versionData['version'] as String?;
      }
      return versionData as String?;
    } catch (_) {
      return null;
    }
  }
  
  Future<String> downloadConfig(String url) async {
    final appLocalizations = AppLocalizations.current;
    try {
      final response = await _primaryClient.get(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      
      if (response.statusCode != HttpStatus.ok) {
        throw '${appLocalizations.configDownloadFailed}: HTTP ${response.statusCode}';
      }
      
      return response.data as String;
    } on DioException catch (error) {
      if (_shouldRetryWithProxy(error)) {
        final response = await _fallbackClient.get(
          url,
          options: Options(responseType: ResponseType.plain),
        );
        return response.data as String;
      }
      
      throw appLocalizations.configDownloadFailed;
    }
  }
}

class _ApiEndpoints {
  const _ApiEndpoints();
  
  String get login => '/login';
  String get logout => '/logout';
  String get userInfo => '/information';
  String get managedConfig => '/managed/flclash';
  String get announcement => '/announcement';
  String get version => '/version/get';
}

