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
    _initializeClients();
  }
  
  static const _apiBase = 'https://oics.net/api/v1';
  static const _serviceCheckUrl = 'https://oics.net/check';
  static const _timeoutSeconds = 10;
  static const _endpoints = _ApiEndpoints();
  
  late final Dio _primaryClient;
  late final Dio _fallbackClient;
  
  BaseOptions get _baseOptions => BaseOptions(
    baseUrl: _apiBase,
    connectTimeout: const Duration(seconds: _timeoutSeconds),
    receiveTimeout: const Duration(seconds: _timeoutSeconds * 2),
    sendTimeout: const Duration(seconds: _timeoutSeconds),
    headers: {'User-Agent': appName},
  );
  
  void _initializeClients() {
    _primaryClient = Dio(_baseOptions);
    _fallbackClient = Dio(_baseOptions)
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.findProxy = (uri) => FlClashHttpOverrides.handleFindProxy(uri);
          return client;
        },
      );
  }
  
  bool _isNetworkIssue(DioException error) {
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.receiveTimeout;
  }
  
  bool _shouldRetryWithProxy(DioException error) {
    return globalState.appState.runTime != null && _isNetworkIssue(error);
  }
  
  Future<Map<String, dynamic>> _request({
    required String endpoint,
    required Map<String, dynamic> payload,
    bool isLoginAttempt = false,
  }) async {
    try {
      return _handleResponse(await _primaryClient.post(endpoint, data: payload));
    } on DioException catch (primaryError) {
      if (_shouldRetryWithProxy(primaryError)) {
        try {
          return _handleResponse(await _fallbackClient.post(endpoint, data: payload));
        } on DioException catch (_) {}
      }
      throw _buildErrorMessage(primaryError, isLoginAttempt: isLoginAttempt);
    }
  }
  
  Future<Response> _getWithFallback(String url, {Options? options}) async {
    try {
      return await _primaryClient.get(url, options: options);
    } on DioException catch (primaryError) {
      if (_shouldRetryWithProxy(primaryError)) {
        return await _fallbackClient.get(url, options: options);
      }
      rethrow;
    }
  }
  
  Map<String, dynamic> _handleResponse(Response response) {
    final l10n = AppLocalizations.current;
    if (response.statusCode != HttpStatus.ok) {
      throw 'HTTP ${response.statusCode}: ${l10n.serverError}';
    }
    
    final data = response.data as Map<String, dynamic>?;
    if (data == null) {
      throw l10n.emptyResponse;
    }
    
    if ((data['ret'] as int?) != 200) {
      throw data['msg'] as String? ?? l10n.unknownError;
    }
    
    return data;
  }
  
  String _buildErrorMessage(DioException error, {bool isLoginAttempt = false}) {
    final l10n = AppLocalizations.current;
    String message = switch (error.type) {
      DioExceptionType.connectionTimeout => l10n.connectionTimeout,
      DioExceptionType.sendTimeout => l10n.sendTimeout,
      DioExceptionType.receiveTimeout => l10n.receiveTimeout,
      DioExceptionType.badCertificate => l10n.sslError,
      DioExceptionType.cancel => l10n.requestCancelled,
      DioExceptionType.badResponse => 'HTTP ${error.response?.statusCode}',
      _ => l10n.networkError,
    };
    
    if (isLoginAttempt && _isNetworkIssue(error)) {
      message += '\n${l10n.checkNetworkConnection}';
    }
    
    return message;
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
  
  Future<void> logout(String token) async {
    try {
      await _request(
        endpoint: _endpoints.logout,
        payload: {'access_token': token},
      );
    } catch (_) {}
  }
  
  Future<CloudProfile> fetchUserProfile(String token) async {
    final response = await _request(
      endpoint: _endpoints.userInfo,
      payload: {'access_token': token},
    );
    return CloudProfile.fromApiResponse(response['data'] as Map<String, dynamic>);
  }
  
  Future<CloudConfigInfo> fetchConfigUrl({
    required String token,
    Map<String, String>? extraParams,
  }) async {
    final payload = <String, dynamic>{'access_token': token};
    
    if (extraParams != null && extraParams.isNotEmpty) {
      payload['optional_params'] = '&${extraParams.entries.map((e) => '${e.key}=${e.value}').join('&')}';
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
      return CloudNotification.fromApiResponse(data['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
  
  Future<String?> checkServiceHealth() async {
    try {
      final response = await _getWithFallback(
        _serviceCheckUrl,
        options: Options(responseType: ResponseType.plain),
      );
      
      if (response.statusCode != HttpStatus.ok) return 'Service Check Failed';
      final content = response.data?.toString().trim() ?? '';
      return content == 'success' ? null : 'Service Check Failed';
    } on DioException catch (error) {
      return _buildErrorMessage(error);
    } catch (e) {
      return e.toString();
    }
  }
  
  Future<String?> fetchLatestVersion() async {
    try {
      final data = _handleResponse(await _primaryClient.get(_endpoints.version));
      final versionData = data['data'];
      return versionData is Map<String, dynamic>
          ? versionData['version'] as String?
          : versionData as String?;
    } catch (_) {
      return null;
    }
  }
  
  Future<String> downloadConfig(String url) async {
    final l10n = AppLocalizations.current;
    try {
      final response = await _getWithFallback(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      
      if (response.statusCode != HttpStatus.ok) {
        throw '${l10n.configDownloadFailed}: HTTP ${response.statusCode}';
      }
      return response.data as String;
    } on DioException {
      throw l10n.configDownloadFailed;
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

