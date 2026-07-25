import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/services/age_crypto.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

// -- Constants --
const int _defaultConnectTimeoutMs = 10000;
const int _defaultReceiveTimeoutMs = 15000;
const int _httpOk = 200;
const int _httpServerError = 500;

// Marks a request as non-idempotent (balance/order/email side effects). Such
// requests must never be hedged to a spare domain or retried, otherwise a slow
// backend response could be processed twice (e.g. double charge).
@visibleForTesting
const String cloudNonIdempotentExtraKey = 'flclash_non_idempotent';

@visibleForTesting
Map<String, dynamic> buildDeleteAccountRequestData({
  required String password,
  String? twoFactorCode,
}) {
  final normalizedCode = twoFactorCode?.trim();
  return {
    'passwd': password,
    'confirmation': 'DELETE',
    if (normalizedCode != null && normalizedCode.isNotEmpty)
      'code': normalizedCode,
  };
}

String _apiRootUrl(String domain) {
  final normalizedDomain = domain.trim();
  if (normalizedDomain.isEmpty) {
    throw ArgumentError.value(
      domain,
      'domain',
      'API domain must be configured',
    );
  }
  return 'https://$normalizedDomain';
}

String _apiV1BaseUrl(String domain) => '${_apiRootUrl(domain)}/api/v1';

HttpClientAdapter _createCloudApiAdapter() {
  return createFlClashHttpClientAdapter(
    findProxy: FlClashHttpOverrides.handleCloudApiFindProxy,
    allowBadCertificate: () => FlClashTemporaryTls.allowBadCertificate,
  );
}

// -- DTOs --
class CloudApiResponse<T> {
  final int ret;
  final String? msg;
  final T? data;
  final String? smart;

  CloudApiResponse({required this.ret, this.msg, this.data, this.smart});

  factory CloudApiResponse.fromJson(dynamic jsonData) {
    if (jsonData is String) {
      try {
        jsonData = jsonDecode(jsonData);
      } catch (_) {}
    }
    if (jsonData is Map) {
      return CloudApiResponse<T>(
        ret: jsonData['ret'] is int
            ? jsonData['ret']
            : int.tryParse(jsonData['ret']?.toString() ?? '') ?? 0,
        msg: jsonData['msg']?.toString(),
        data: jsonData['data'],
        smart: jsonData['smart']?.toString(),
      );
    }
    return CloudApiResponse<T>(ret: 0, msg: 'Invalid response format');
  }

  bool get isSuccess => ret == _httpOk;
}

class CloudApiException implements Exception {
  final String message;

  const CloudApiException(this.message);

  static bool isHandledUnauthorized(Object error) {
    return error is CloudApiUnauthorizedHandledException;
  }

  static bool isUnauthorized(Object error) {
    if (isHandledUnauthorized(error)) {
      return false;
    }
    final message = clean(error).toLowerCase();
    return message == 'unauthorized' ||
        message.contains('unauthorized') ||
        message.contains('401');
  }

  static String clean(Object error) {
    if (error is CloudApiException) {
      return _cleanMessage(error.message);
    }
    return _cleanMessage(error.toString());
  }

  static bool isCertificateVerifyFailed(Object error) {
    return FlClashTemporaryTls.isCertificateVerifyFailed(error);
  }

  static String _cleanMessage(String value) {
    var message = value.trim();
    if (FlClashTemporaryTls.isCertificateVerifyFailed(message)) {
      return appLocalizations.invalidCertificateTitle;
    }
    final prefixes = [
      RegExp(r'^_?Excep(?:t)?ion[:：]\s*', caseSensitive: false),
      RegExp(r'^CloudApiException[:：]\s*', caseSensitive: false),
      RegExp(r'^Health check fail(?:e)?d[:：]\s*', caseSensitive: false),
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final prefix in prefixes) {
        final updated = message.replaceFirst(prefix, '').trim();
        if (updated != message) {
          message = updated;
          changed = true;
        }
      }
    }
    if (message.isEmpty || message.toLowerCase() == 'null') {
      return 'Connection failed';
    }
    return message;
  }

  @override
  String toString() => clean(this);
}

class CloudApiUnauthorizedHandledException implements Exception {
  const CloudApiUnauthorizedHandledException();

  @override
  String toString() => 'Unauthorized';
}

class CloudApiService {
  Dio? _dio;
  String? _cachedToken;

  static final RegExp _bearerTokenPattern = RegExp(
    r'^Bearer\s+(.+)$',
    caseSensitive: false,
  );

  CloudApiService._();

  Dio get _client {
    return _dio ??= _createDio();
  }

  Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: _apiV1BaseUrl(Secrets.primaryApiDomain),
        connectTimeout: const Duration(milliseconds: _defaultConnectTimeoutMs),
        receiveTimeout: const Duration(milliseconds: _defaultReceiveTimeoutMs),
        followRedirects: true,
        validateStatus: (status) => status != null && status < _httpServerError,
        headers: {
          'User-Agent': 'FlClash for oixCloud',
          'Accept': 'application/json',
        },
      ),
    );
    dio.httpClientAdapter = HedgedApiAdapter(_createCloudApiAdapter());
    dio.interceptors.addAll([
      // Authorization interceptor
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.extra['skipAuth'] != true &&
              _cachedToken != null &&
              _cachedToken!.isNotEmpty) {
            final token = _cachedToken!;
            options.headers['Authorization'] = 'Bearer $token';
          }

          handler.next(options);
        },
        onResponse: (response, handler) {
          if (response.statusCode == 401 ||
              (response.data is Map && response.data['ret'] == 401)) {
            _cachedToken = null;
          }
          handler.next(response);
        },
        onError: (DioException e, handler) {
          if (e.response?.statusCode == 401) {
            _cachedToken = null;
          }
          handler.next(e);
        },
      ),
      // Retry Interceptor
      RetryInterceptor(dio: dio),
    ]);
    return dio;
  }

  static final CloudApiService _instance = CloudApiService._();
  factory CloudApiService() => _instance;

  bool get temporarilyAllowInsecureTls =>
      FlClashTemporaryTls.allowBadCertificate;

  Future<T> runWithInsecureTls<T>(Future<T> Function() action) async {
    return FlClashTemporaryTls.runWithBadCertificateAllowed(action);
  }

  Future<bool> confirmInsecureTlsRetry(Object error) async {
    if (temporarilyAllowInsecureTls ||
        !CloudApiException.isCertificateVerifyFailed(error)) {
      return false;
    }

    final allow = await globalState.showMessage(
      title: appLocalizations.invalidCertificateTitle,
      message: TextSpan(text: appLocalizations.invalidCertificateContent),
      confirmText: appLocalizations.allowTemporarily,
      cancelText: appLocalizations.cancel,
    );
    return allow == true;
  }

  static String? normalizeToken(String? token) {
    if (token == null) return null;

    var normalized = _stripWrappingQuotes(token.trim());
    if (normalized.isEmpty) return null;

    final bearerMatch = _bearerTokenPattern.firstMatch(normalized);
    if (bearerMatch != null) {
      normalized = bearerMatch.group(1)?.trim() ?? '';
    }

    normalized = _stripWrappingQuotes(normalized);

    return normalized.isEmpty ? null : normalized;
  }

  static String _stripWrappingQuotes(String value) {
    var normalized = value;
    while (normalized.length >= 2 &&
        ((normalized.startsWith('"') && normalized.endsWith('"')) ||
            (normalized.startsWith("'") && normalized.endsWith("'")))) {
      normalized = normalized.substring(1, normalized.length - 1).trim();
    }
    return normalized;
  }

  void setToken(String? token) {
    final normalizedToken = normalizeToken(token);
    if (normalizedToken == null || normalizedToken.isEmpty) {
      _cachedToken = null;
    } else {
      _cachedToken = normalizedToken;
    }
  }

  Future<void> checkServiceHealth() async {
    try {
      final res = await _client.get(
        '${_apiRootUrl(Secrets.primaryApiDomain)}/check',
        options: Options(extra: {'skipAuth': true}),
      );
      if (res.statusCode != _httpOk) {
        final statusCode = res.statusCode?.toString() ?? 'unknown';
        throw CloudApiException('Service unavailable (Status: $statusCode)');
      }
    } on DioException catch (e) {
      throw CloudApiException(_formatHealthCheckError(e));
    }
  }

  static String _formatHealthCheckError(DioException error) {
    final fallback = switch (error.type) {
      DioExceptionType.connectionTimeout => 'Connection timed out',
      DioExceptionType.sendTimeout => 'Send timed out',
      DioExceptionType.receiveTimeout => 'Response timed out',
      DioExceptionType.badCertificate => 'Invalid certificate',
      DioExceptionType.badResponse =>
        'Server returned ${error.response?.statusCode ?? 'an error'}',
      DioExceptionType.cancel => 'Request canceled',
      DioExceptionType.connectionError => 'Connection failed',
      DioExceptionType.unknown => 'Unknown network error',
    };
    if (error.type != DioExceptionType.unknown) {
      return fallback;
    }
    final message = error.message?.trim();
    if (message == null || message.isEmpty || message == 'null') {
      return fallback;
    }
    return message;
  }

  ({CloudProfile profile, CloudNotification? announcement}) _parseUserInfo(
    dynamic infoData,
  ) {
    if (infoData is! Map) {
      throw Exception('Invalid user data format');
    }
    final info = infoData;

    final requiredKeys = [
      'plan',
      'plan_time',
      'used',
      'traffic',
      'today_used',
      'unused',
      'money',
      'aff_money',
      'integral',
    ];
    for (final key in requiredKeys) {
      if (!info.containsKey(key)) {
        throw FormatException('Missing required field: $key');
      }
      if (info[key] != null && info[key] is! String && info[key] is! num) {
        throw FormatException('Invalid type for field: $key');
      }
    }

    CloudNotification? announcement;
    if (info['announcement'] is Map) {
      final ann = info['announcement'];
      announcement = CloudNotification(
        cleanMessage: ann['content']?.toString() ?? '',
        publishTime:
            DateTime.tryParse(ann['date']?.toString() ?? '') ?? DateTime.now(),
      );
    }

    DateTime expireTime;
    try {
      final pt = info['plan_time']?.toString() ?? '';
      expireTime = DateTime.tryParse(pt) ?? DateTime.now();
    } catch (_) {
      expireTime = DateTime.now();
    }

    final usedBytes = _parseTraffic(info['used']?.toString());
    final totalBytes = _parseTraffic(info['traffic']?.toString());
    final progress = totalBytes > 0
        ? (usedBytes / totalBytes).clamp(0.0, 1.0)
        : 0.0;

    final profile = CloudProfile(
      subscription: info['plan']?.toString() ?? '',
      planCode: info['plan_code']?.toString() ?? '',
      planRank: int.tryParse(info['plan_rank']?.toString() ?? ''),
      nodeAccess:
          (info['node_access'] as List?)
              ?.map((value) => value?.toString() ?? '')
              .where((value) => value.isNotEmpty)
              .toList() ??
          const [],
      expireTime: expireTime,
      todayUsed: info['today_used']?.toString() ?? '0',
      totalUsed: info['used']?.toString() ?? '0',
      totalTraffic: info['traffic']?.toString() ?? '0',
      usageProgress: progress,
      remaining: info['unused']?.toString() ?? '0',
      balance: info['money']?.toString() ?? '0.00',
      commission: info['aff_money']?.toString() ?? '0.00',
      points: info['integral']?.toString() ?? '50 / 50',
    );

    return (profile: profile, announcement: announcement);
  }

  /// Parses a human traffic string ("1.5 GB", "200 MiB", "42") into bytes.
  /// Multipliers always follow the 1024 (binary) convention regardless of
  /// whether the unit is written `MB` or `MiB` — the server uses both forms
  /// interchangeably.
  int _parseTraffic(String? value) {
    if (value == null || value.trim().isEmpty) return 0;

    final trafficRegex = RegExp(
      r'^(\d+(?:\.\d+)?)\s*([KMGT])?(i)?B?$',
      caseSensitive: false,
    );
    final match = trafficRegex.firstMatch(value.trim());
    if (match == null) {
      commonPrint.log('unrecognized traffic value, treating as 0: $value');
      return 0;
    }

    final numValue = double.tryParse(match.group(1) ?? '0') ?? 0.0;
    final unit = (match.group(2) ?? '').toUpperCase();
    final multiplier = switch (unit) {
      'T' => 1 << 40,
      'G' => 1 << 30,
      'M' => 1 << 20,
      'K' => 1 << 10,
      _ => 1,
    };
    return (numValue * multiplier).round();
  }

  void _validateInput(String email, String password) {
    if (email.isEmpty || !RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email)) {
      throw Exception('Invalid email format');
    }
    if (password.isEmpty) {
      throw Exception('Password cannot be empty');
    }
  }

  Future<
    ({String token, CloudProfile profile, CloudNotification? announcement})
  >
  login(String email, String password) async {
    _validateInput(email, password);

    final res = await _client.post(
      '/login',
      data: FormData.fromMap({
        'email': email,
        'passwd': password,
        'token_expire': 365,
      }),
      options: _writeOptions(Options(extra: {'skipAuth': true})),
    );

    final responseDto = CloudApiResponse<Map<dynamic, dynamic>>.fromJson(
      res.data,
    );

    if (responseDto.isSuccess && responseDto.data != null) {
      final info = responseDto.data!;
      if (info['token'] != null) {
        final tokenStr = info['token']?.toString() ?? '';
        if (tokenStr.isEmpty) throw Exception('API returned empty token');

        setToken(tokenStr);
        final parsed = _parseUserInfo(info);
        return (
          token: tokenStr,
          profile: parsed.profile,
          announcement: parsed.announcement,
        );
      }
    }

    throw Exception(responseDto.msg ?? 'Login failed: Invalid response');
  }

  Future<CloudRegisterConfig> fetchRegisterConfig() async {
    final res = await _client.post(
      '/register/config',
      options: Options(extra: {'skipAuth': true}),
    );
    final responseDto = CloudApiResponse<Map<dynamic, dynamic>>.fromJson(
      res.data,
    );
    if (responseDto.isSuccess && responseDto.data is Map) {
      return CloudRegisterConfig.fromJson(
        Map<String, dynamic>.from(responseDto.data as Map),
      );
    }
    throw Exception(responseDto.msg ?? 'Failed to load register config');
  }

  Future<void> sendEmailVerify(String email) async {
    if (email.isEmpty || !RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email)) {
      throw Exception('Invalid email format');
    }
    final res = await _client.post(
      '/register/send_email',
      data: FormData.fromMap({'email': email}),
      options: _writeOptions(Options(extra: {'skipAuth': true})),
    );
    final responseDto = CloudApiResponse<dynamic>.fromJson(res.data);
    if (!responseDto.isSuccess) {
      throw Exception(responseDto.msg ?? 'Failed to send verification code');
    }
  }

  Future<void> sendPasswordReset(String email) async {
    if (email.isEmpty || !RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email)) {
      throw Exception('Invalid email format');
    }
    final res = await _client.post(
      '/password/reset',
      data: FormData.fromMap({'email': email}),
      options: _writeOptions(Options(extra: {'skipAuth': true})),
    );
    final responseDto = CloudApiResponse<dynamic>.fromJson(res.data);
    if (!responseDto.isSuccess) {
      throw Exception(responseDto.msg ?? 'Failed to send reset email');
    }
  }

  Future<void> resetPasswordWithToken({
    required String token,
    required String password,
  }) async {
    final res = await _client.post(
      '/password/token',
      data: FormData.fromMap({
        'token': token,
        'passwd': password,
        'repasswd': password,
      }),
      options: _writeOptions(Options(extra: {'skipAuth': true})),
    );
    final responseDto = CloudApiResponse<dynamic>.fromJson(res.data);
    if (!responseDto.isSuccess) {
      throw Exception(responseDto.msg ?? 'Failed to reset password');
    }
  }

  Future<
    ({String token, CloudProfile profile, CloudNotification? announcement})
  >
  register({
    required String name,
    required String email,
    required String password,
    String? inviteCode,
    String? emailCode,
  }) async {
    final res = await _client.post(
      '/register',
      data: FormData.fromMap({
        'name': name,
        'email': email,
        'passwd': password,
        'repasswd': password,
        if (inviteCode != null && inviteCode.isNotEmpty) 'code': inviteCode,
        if (emailCode != null && emailCode.isNotEmpty) 'emailcode': emailCode,
        'token_expire': 365,
      }),
      options: _writeOptions(Options(extra: {'skipAuth': true})),
    );
    return _parseAuthResult(res.data);
  }

  ({String token, CloudProfile profile, CloudNotification? announcement})
  _parseAuthResult(dynamic data) {
    final responseDto = CloudApiResponse<Map<dynamic, dynamic>>.fromJson(data);
    if (responseDto.isSuccess && responseDto.data != null) {
      final info = responseDto.data!;
      final tokenStr = info['token']?.toString() ?? '';
      if (tokenStr.isEmpty) throw Exception('API returned empty token');
      setToken(tokenStr);
      final parsed = _parseUserInfo(info);
      return (
        token: tokenStr,
        profile: parsed.profile,
        announcement: parsed.announcement,
      );
    }
    throw Exception(responseDto.msg ?? 'Request failed');
  }

  Future<({CloudProfile profile, CloudNotification? announcement})>
  getUserInfo() async {
    final token = _cachedToken;
    if (token == null || token.isEmpty) {
      throw Exception('Missing access token');
    }

    final res = await _client.post('/information');
    final responseDto = CloudApiResponse<Map<dynamic, dynamic>>.fromJson(
      res.data,
    );

    if (res.statusCode == 401 || responseDto.ret == 401) {
      setToken(null);
      throw const CloudApiException('Unauthorized');
    }

    if (!responseDto.isSuccess || responseDto.data == null) {
      throw Exception(responseDto.msg ?? 'Failed to parse user info');
    }

    return _parseUserInfo(responseDto.data!);
  }

  Future<void> logout() async {
    if (_cachedToken == null || _cachedToken!.isEmpty) return;
    final res = await _client.post('/logout');
    final responseDto = CloudApiResponse<dynamic>.fromJson(res.data);
    if (res.statusCode == 401 || responseDto.ret == 401) {
      setToken(null);
      return;
    }
    if (!responseDto.isSuccess) {
      throw CloudApiException(responseDto.msg ?? 'Failed to revoke token');
    }
  }

  Future<void> deleteAccount({
    required String password,
    String? twoFactorCode,
  }) async {
    if (_cachedToken == null || _cachedToken!.isEmpty) {
      throw const CloudApiException('Unauthorized');
    }
    final res = await _client.post(
      '/delete',
      data: FormData.fromMap(
        buildDeleteAccountRequestData(
          password: password,
          twoFactorCode: twoFactorCode,
        ),
      ),
      options: _writeOptions(),
    );
    final responseDto = CloudApiResponse<dynamic>.fromJson(res.data);
    _ensureAuthorized(res.statusCode, responseDto.ret);
    if (!responseDto.isSuccess) {
      throw CloudApiException(
        responseDto.msg ?? appLocalizations.deleteAccountFailed,
      );
    }
  }

  String _flclashTimestamp() {
    return (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
  }

  String _flclashHmac(String message) {
    final key = utf8.encode(Secrets.flClashAppSecret);
    final hmac = Hmac(sha256, key);
    return hmac.convert(utf8.encode(message)).toString();
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  Future<(Uint8List, String?)> fetchManagedConfig(String paramString) async {
    try {
      final queryParameters = <String, dynamic>{};
      final cleaned = paramString.startsWith('&')
          ? paramString.substring(1)
          : paramString;
      if (cleaned.isNotEmpty) {
        Uri.splitQueryString(cleaned).forEach((k, v) {
          queryParameters[k] = v;
        });
      }

      final timestamp = _flclashTimestamp();

      final identity = await AgeCrypto.generateIdentity();
      final signature = _flclashHmac('$timestamp.${identity.recipient}');

      final headers = <String, String>{
        'X-Flclash-Timestamp': timestamp,
        'X-Flclash-Signature': signature,
        'X-Flclash-Age-Pubkey': identity.recipient,
      };

      final res = await _client.get<Map<String, dynamic>>(
        '/managed/flclash/direct',
        queryParameters: queryParameters,
        options: Options(headers: headers, responseType: ResponseType.json),
      );

      if (res.statusCode == 401 || res.data?['ret'] == 401) {
        setToken(null);
        throw const CloudApiException('Unauthorized');
      }

      if (res.statusCode != 200) {
        throw CloudApiException('Config request failed (${res.statusCode})');
      }

      final configB64 = res.data?['config'] as String?;
      final userinfo = res.data?['userinfo'] as String?;

      if (configB64 == null || configB64.isEmpty) {
        throw const CloudApiException('Server returned empty config');
      }
      Uint8List configBytes;
      try {
        configBytes = base64Decode(configB64);
      } on FormatException {
        throw const CloudApiException('Server returned invalid config');
      }

      final responseSignature = res.headers.value(
        'X-Flclash-Response-Signature',
      );
      if (responseSignature == null || responseSignature.isEmpty) {
        throw const CloudApiException('Missing response signature');
      }
      final expected = _flclashHmac('$timestamp.$configB64');
      if (!_constantTimeEquals(responseSignature, expected)) {
        throw const CloudApiException('Response signature mismatch');
      }

      if (!AgeCrypto.isArmored(configBytes)) {
        throw const CloudApiException('Server returned invalid config');
      }
      try {
        final plaintext = await AgeCrypto.decrypt(configBytes, identity);
        return (plaintext, userinfo);
      } catch (_) {
        throw const CloudApiException('Server returned invalid config');
      }
    } catch (e) {
      if (e is DioException) {
        throw CloudApiException(
          'Unable to get oixCloud config: ${_formatHealthCheckError(e)}',
        );
      }
      rethrow;
    }
  }

  // -- Store / Purchase --

  // Tags an Options as non-idempotent so hedging and retries are disabled.
  Options _writeOptions([Options? base]) {
    final options = base ?? Options();
    final extra = <String, dynamic>{
      ...?options.extra,
      cloudNonIdempotentExtraKey: true,
    };
    return options.copyWith(extra: extra);
  }

  void _ensureAuthorized(int? statusCode, int ret) {
    if (statusCode == 401 || ret == 401) {
      setToken(null);
      throw const CloudApiException('Unauthorized');
    }
  }

  Future<List<StorePlan>> fetchPlans() async {
    final res = await _client.post('/shop/list');
    final dto = CloudApiResponse<Map<dynamic, dynamic>>.fromJson(res.data);
    _ensureAuthorized(res.statusCode, dto.ret);
    if (!dto.isSuccess || dto.data == null) {
      throw CloudApiException(dto.msg ?? appLocalizations.fetchPlansFailed);
    }
    return decodeStorePlans(dto.data!['shops']);
  }

  Future<List<BoughtRecord>> fetchBought() async {
    final res = await _client.post('/shop/bought');
    final dto = CloudApiResponse<Map<dynamic, dynamic>>.fromJson(res.data);
    _ensureAuthorized(res.statusCode, dto.ret);
    if (!dto.isSuccess || dto.data == null) {
      throw CloudApiException(dto.msg ?? appLocalizations.fetchOrdersFailed);
    }
    return decodeBoughtRecords(dto.data!['boughts']);
  }

  Future<List<PaymentMethodOption>> fetchPaymentMethods() async {
    final res = await _client.post('/pay/methods');
    dynamic data = res.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
    if (data is Map && data['ret'] == 401) {
      setToken(null);
      throw const CloudApiException('Unauthorized');
    }
    final list = (data is Map ? data['result'] : null) as List? ?? const [];
    return list
        .whereType<Map>()
        .map((e) => PaymentMethodOption.fromJson(e))
        .toList();
  }

  Future<({bool success, String message})> _postShopAction(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _client.post(
      path,
      data: FormData.fromMap(body),
      options: _writeOptions(),
    );
    final dto = CloudApiResponse<dynamic>.fromJson(res.data);
    _ensureAuthorized(res.statusCode, dto.ret);
    return (
      success: dto.isSuccess,
      message:
          dto.msg ??
          (dto.isSuccess
              ? appLocalizations.operationSuccess
              : appLocalizations.operationFailed),
    );
  }

  Future<({bool success, String message})> buyPlanWithBalance(
    int shopId, {
    String? billingPeriod,
    String? coupon,
    bool autoRenew = false,
  }) {
    return _postShopAction('/shop/buy', {
      'shop': shopId,
      if (billingPeriod != null && billingPeriod.isNotEmpty)
        'billing_period': billingPeriod,
      if (coupon != null && coupon.isNotEmpty) 'coupon_code': coupon,
      'autorenew': autoRenew ? 1 : 0,
    });
  }

  Future<({bool success, String message})> upgradePlan(
    int boughtId,
    int targetShopId, {
    String? coupon,
  }) {
    return _postShopAction('/shop/upgrade', {
      'bought_id': boughtId,
      'target_shop_id': targetShopId,
      if (coupon != null && coupon.isNotEmpty) 'coupon_code': coupon,
    });
  }

  Future<({bool success, String message})> activatePlan(int boughtId) {
    return _postShopAction('/shop/activate', {'id': boughtId});
  }

  Future<({bool success, String message})> earlyRenewPlan(
    int boughtId, {
    String? coupon,
  }) {
    return _postShopAction('/shop/early_renew', {
      'id': boughtId,
      if (coupon != null && coupon.isNotEmpty) 'coupon_code': coupon,
    });
  }

  /// 发起充值（任意金额进入余额）。
  Future<PaymentInitiation> createRecharge({
    required String payment,
    required double amount,
    String? type,
    String? coin,
  }) {
    final body = <String, dynamic>{
      'payment': payment,
      'amount': amount,
      'price': amount,
      if (type != null && type.isNotEmpty) 'type': type,
      if (coin != null && coin.isNotEmpty) 'coin': coin,
    };
    return _initiatePayment('/pay/recharge', body);
  }

  /// 按套餐直接下单（无需先充值）。价格为 0 时服务端直接用余额完成购买。
  Future<PaymentInitiation> createOrder({
    required int shopId,
    required String payment,
    String? billingPeriod,
    String? type,
    String? coin,
    String? coupon,
    bool autoRenew = false,
  }) {
    final body = <String, dynamic>{
      'shop': shopId,
      'payment': payment,
      'autorenew': autoRenew ? 1 : 0,
      if (billingPeriod != null && billingPeriod.isNotEmpty)
        'billing_period': billingPeriod,
      if (type != null && type.isNotEmpty) 'type': type,
      if (coin != null && coin.isNotEmpty) 'coin': coin,
      if (coupon != null && coupon.isNotEmpty) 'coupon_code': coupon,
    };
    return _initiatePayment('/pay/order', body);
  }

  Future<PaymentInitiation> _initiatePayment(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _client.post(
      path,
      data: FormData.fromMap(body),
      options: _writeOptions(
        Options(
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status < _httpServerError,
        ),
      ),
    );
    if (res.statusCode == 401 || (res.data is Map && res.data['ret'] == 401)) {
      setToken(null);
      throw const CloudApiException('Unauthorized');
    }
    return PaymentInitiation.parse(
      res.data,
      statusCode: res.statusCode,
      redirectLocation: res.headers.value('location'),
    );
  }

  /// 查询支付订单状态：返回 true 表示已支付。
  Future<bool> queryPaymentPaid(
    String pid, {
    String payment = 'cryptapi',
  }) async {
    final res = await _client.post(
      '/pay/status',
      data: FormData.fromMap({'pid': pid, 'payment': payment}),
    );
    final dto = CloudApiResponse<dynamic>.fromJson(res.data);
    _ensureAuthorized(res.statusCode, dto.ret);
    dynamic data = res.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
    if (data is! Map) return false;
    final result = data['result'];
    final status = result is num
        ? result.toInt()
        : int.tryParse(result?.toString() ?? '') ?? 0;
    return status == 1;
  }
}

// -- Happy Eyeballs hedged adapter for the oixCloud API --
@visibleForTesting
class HedgedApiAdapter implements HttpClientAdapter {
  HedgedApiAdapter(this._inner, {List<String> Function()? domains})
    : _domains = domains ?? (() => Secrets.apiDomains);

  final HttpClientAdapter _inner;
  final List<String> Function() _domains;

  static const Duration _hedgeDelay = Duration(milliseconds: 250);

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final domains = _domains();
    final host = options.uri.host.toLowerCase();
    if (domains.length < 2 ||
        domains.first.toLowerCase() != host ||
        options.extra[cloudNonIdempotentExtraKey] == true) {
      return _inner.fetch(options, requestStream, cancelFuture);
    }

    Uint8List? body;
    if (requestStream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
      body = builder.takeBytes();
    }

    final completer = Completer<ResponseBody>();
    final cancellers = <Completer<void>>[];
    var settled = false;
    var failures = 0;
    var launched = 0;
    var allLaunched = false;
    Object? lastError;
    StackTrace? lastStack;

    void maybeFail() {
      if (settled || !allLaunched || failures < launched) {
        return;
      }
      settled = true;
      completer.completeError(
        lastError ?? Exception('All API endpoints failed'),
        lastStack ?? StackTrace.current,
      );
    }

    void launch(String domain) {
      if (settled) {
        return;
      }
      launched++;
      final canceller = Completer<void>();
      cancellers.add(canceller);
      final uri = options.uri.replace(host: domain);
      final perHost = options.copyWith(
        baseUrl: uri.origin,
        path: uri.path,
        queryParameters: Map<String, dynamic>.from(uri.queryParameters),
      );
      final cancelSignal = cancelFuture == null
          ? canceller.future
          : Future.any<void>([cancelFuture, canceller.future]);
      unawaited(
        _inner
            .fetch(
              perHost,
              body == null ? null : Stream<Uint8List>.value(body),
              cancelSignal,
            )
            .then(
              (response) {
                if (settled) {
                  unawaited(_drainResponse(response));
                  return;
                }
                settled = true;
                for (final other in cancellers) {
                  if (!identical(other, canceller) && !other.isCompleted) {
                    other.complete();
                  }
                }
                completer.complete(response);
              },
              onError: (Object error, StackTrace stack) {
                if (canceller.isCompleted) {
                  return;
                }
                failures++;
                lastError = error;
                lastStack = stack;
                maybeFail();
              },
            ),
      );
    }

    launch(host);

    unawaited(
      Future<void>.delayed(_hedgeDelay).then((_) {
        if (settled) {
          return;
        }
        for (final domain in domains.skip(1)) {
          launch(domain);
        }
        allLaunched = true;
        maybeFail();
      }),
    );

    return completer.future;
  }

  Future<void> _drainResponse(ResponseBody response) async {
    try {
      await response.stream.drain<void>();
    } catch (_) {}
  }
}

// -- Interceptor to handle Retries --
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int retries;

  RetryInterceptor({required this.dio, this.retries = 2});

  static const _retryHandledKey = 'retryHandled';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (!_shouldRetry(err) ||
        err.requestOptions.extra[_retryHandledKey] == true ||
        err.requestOptions.extra[cloudNonIdempotentExtraKey] == true) {
      return super.onError(err, handler);
    }

    final retryExtra = Map<String, dynamic>.from(err.requestOptions.extra)
      ..[_retryHandledKey] = true;
    DioException lastError = err;

    for (int attempt = 1; attempt <= retries; attempt++) {
      await Future.delayed(
        Duration(milliseconds: 500 * pow(2, attempt).toInt()),
      );
      try {
        final response = await dio.fetch(
          _copyRequestOptionsForRetry(err.requestOptions, retryExtra),
        );
        return handler.resolve(response);
      } on DioException catch (e) {
        lastError = e;
        if (!_shouldRetry(e)) break;
      }
    }

    return super.onError(lastError, handler);
  }

  RequestOptions _copyRequestOptionsForRetry(
    RequestOptions requestOptions,
    Map<String, dynamic> extra,
  ) {
    return requestOptions.copyWith(
      data: _cloneRequestData(requestOptions.data),
      extra: extra,
    );
  }

  Object? _cloneRequestData(Object? data) {
    return data is FormData ? data.clone() : data;
  }

  bool _shouldRetry(DioException err) {
    return err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError ||
        (err.type == DioExceptionType.badResponse &&
            (err.response?.statusCode ?? 0) >= _httpServerError);
  }
}
