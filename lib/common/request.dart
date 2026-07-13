import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/cupertino.dart';

String formatRemoteVersion(String version) {
  final normalized = version.trim();
  return normalized.startsWith('v') ? normalized : 'v$normalized';
}

class Request {
  late final Dio dio;
  late final Dio _clashDio;
  late final Dio _apiDirectDio;
  String? userAgent;

  Request() {
    dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _apiDirectDio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _apiDirectDio.httpClientAdapter = createFlClashHttpClientAdapter(
      findProxy: (_) => 'DIRECT',
      allowBadCertificate: () => FlClashTemporaryTls.allowBadCertificate,
    );
    _clashDio = Dio();
    _clashDio.httpClientAdapter = createFlClashHttpClientAdapter(
      findProxy: FlClashHttpOverrides.handleFindProxy,
      allowBadCertificate: () => FlClashTemporaryTls.allowBadCertificate,
      userAgent: () => appController.ua,
    );
  }

  Map<String, String> get _flclashIdentityHeaders {
    final packageInfo = globalState.packageInfo;
    final headers = <String, String>{};
    if (packageInfo.buildNumber.isNotEmpty) {
      headers['X-Flclash-Build'] = packageInfo.buildNumber;
    }
    return headers;
  }

  ({Uri? authOrigin, Map<String, dynamic>? headers, String url})
  _resolveBasicAuth(String url, Map<String, dynamic>? headers) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.userInfo.isEmpty ||
        (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return (authOrigin: null, headers: headers, url: url);
    }

    final requestUrl = uri.replace(userInfo: '').toString();
    final requestHeaders = Map<String, dynamic>.from(headers ?? const {});
    if (!requestHeaders.containsKey(HttpHeaders.authorizationHeader) &&
        !requestHeaders.containsKey('Authorization')) {
      requestHeaders[HttpHeaders.authorizationHeader] =
          'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)))}';
    }
    return (
      authOrigin: Uri.tryParse(requestUrl),
      headers: requestHeaders,
      url: requestUrl,
    );
  }

  Options _getOptionsForUrl(
    Options options,
    Uri? authOrigin,
    String requestUrl,
  ) {
    if (authOrigin == null) {
      return options;
    }
    final uri = Uri.tryParse(requestUrl);
    if (uri != null &&
        uri.scheme == authOrigin.scheme &&
        uri.host == authOrigin.host &&
        uri.port == authOrigin.port) {
      return options;
    }
    final headers = Map<String, dynamic>.from(options.headers ?? const {});
    headers.remove(HttpHeaders.authorizationHeader);
    headers.remove('Authorization');
    return options.copyWith(headers: headers);
  }

  Future<Response<T>> _getWithRedirect<T>(
    String url, {
    required Options options,
    Dio? client,
  }) async {
    final dio = client ?? _clashDio;
    final request = _resolveBasicAuth(url, options.headers);
    final opts = options.copyWith(
      followRedirects: false,
      headers: request.headers,
      validateStatus: (status) => status != null && status < 400,
    );

    var requestUrl = request.url;
    var response = await dio.get<T>(requestUrl, options: opts);
    int redirectCount = 0;
    while ([
          HttpStatus.movedTemporarily,
          HttpStatus.movedPermanently,
          HttpStatus.seeOther,
          HttpStatus.temporaryRedirect,
          HttpStatus.permanentRedirect,
        ].contains(response.statusCode) &&
        redirectCount < 5) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || location.isEmpty) break;
      final redirectUrl = Uri.parse(requestUrl).resolve(location).toString();
      response = await dio.get<T>(
        redirectUrl,
        options: _getOptionsForUrl(opts, request.authOrigin, redirectUrl),
      );
      requestUrl = redirectUrl;
      redirectCount++;
    }

    if (response.statusCode != null && response.statusCode! >= 400) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
      );
    }
    return response;
  }

  Future<Response<Uint8List>> getFileResponseForUrl(String url) async {
    try {
      final uri = Uri.tryParse(url);
      final isApiDomain = uri != null && Secrets.isApiDomain(uri.host);
      return await _getWithRedirect<Uint8List>(
        url,
        client: isApiDomain ? _apiDirectDio : null,
        options: Options(
          headers: _flclashIdentityHeaders,
          responseType: ResponseType.bytes,
        ),
      );
    } catch (e) {
      commonPrint.log('getFileResponseForUrl error ${e.toString()}');
      if (e is DioException) {
        if (FlClashTemporaryTls.isCertificateVerifyFailed(e)) {
          rethrow;
        }
        if (e.response?.statusCode == HttpStatus.unauthorized) {
          throw 'Unauthorized';
        }
        if (e.type == DioExceptionType.unknown) {
          throw appLocalizations.unknownNetworkError;
        } else if (e.type == DioExceptionType.badResponse) {
          throw appLocalizations.networkException;
        }
        rethrow;
      }
      throw appLocalizations.unknownNetworkError;
    }
  }

  Future<Response<String>> getTextResponseForUrl(String url) async {
    return _getWithRedirect<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
  }

  Future<void> downloadFile(String url, String savePath) async {
    try {
      final saveFile = File(savePath);
      await saveFile.parent.create(recursive: true);
      await dio.download(
        url,
        savePath,
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
    } catch (error) {
      commonPrint.log('downloadFile error ${error.toString()}');
      if (error is DioException) {
        if (error.type == DioExceptionType.unknown) {
          throw appLocalizations.unknownNetworkError;
        } else if (error.type == DioExceptionType.badResponse) {
          throw appLocalizations.networkException;
        }
        rethrow;
      }
      throw appLocalizations.unknownNetworkError;
    }
  }

  Future<MemoryImage?> getImage(String url) async {
    if (url.isEmpty) return null;
    final response = await dio.get<Uint8List>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (data == null) return null;
    return MemoryImage(data);
  }

  Future<String?> checkForUpdate() async {
    for (final domain in Secrets.apiDomains) {
      try {
        final response = await _apiDirectDio.get(
          'https://$domain/api/v1/version/get',
          options: Options(responseType: ResponseType.json),
        );
        if (response.statusCode != 200) continue;
        final data = response.data as Map<String, dynamic>?;
        if (data == null || (data['ret'] as int?) != 200) continue;

        final versionData = data['data'];
        final String? remoteVersion = versionData is Map<String, dynamic>
            ? versionData['version'] as String?
            : versionData as String?;

        if (remoteVersion == null) continue;

        final currentBuildNumber =
            int.tryParse(globalState.packageInfo.buildNumber) ?? 0;
        final remoteBuildNumber =
            int.tryParse(remoteVersion.split('+').last) ?? 0;

        final hasUpdate = remoteBuildNumber > currentBuildNumber;

        if (!hasUpdate) return null;

        return formatRemoteVersion(remoteVersion);
      } catch (_) {
        commonPrint.log(
          'checkForUpdate failed for $domain',
          logLevel: LogLevel.warning,
        );
      }
    }
    throw Exception('checkForUpdate failed for all domains');
  }

  final Map<String, IpInfo Function(Map<String, dynamic>)> _ipInfoSources = {
    'https://ipwho.is': IpInfo.fromIpWhoIsJson,
    'https://api.myip.com': IpInfo.fromMyIpJson,
    'https://ipapi.co/json': IpInfo.fromIpApiCoJson,
    'https://ident.me/json': IpInfo.fromIdentMeJson,
    'http://ip-api.com/json': IpInfo.fromIpAPIJson,
    'https://api.ip.sb/geoip': IpInfo.fromIpSbJson,
    'https://ipinfo.io/json': IpInfo.fromIpInfoIoJson,
  };

  Future<Result<IpInfo?>> checkIp({CancelToken? cancelToken}) async {
    var failureCount = 0;
    final token = cancelToken ?? CancelToken();
    final futures = _ipInfoSources.entries.map((source) async {
      final Completer<Result<IpInfo?>> completer = Completer();
      void handleFailRes() {
        if (!completer.isCompleted && failureCount == _ipInfoSources.length) {
          completer.complete(Result.success(null));
        }
      }

      final future = dio
          .get<Map<String, dynamic>>(
            source.key,
            cancelToken: token,
            options: Options(responseType: ResponseType.json),
          )
          .timeout(const Duration(seconds: 10));
      future
          .then((res) {
            if (res.statusCode == HttpStatus.ok && res.data != null) {
              completer.complete(Result.success(source.value(res.data!)));
              return;
            }
            failureCount++;
            handleFailRes();
          })
          .catchError((e) {
            failureCount++;
            if (e is DioException && e.type == DioExceptionType.cancel) {
              completer.complete(Result.error('cancelled'));
            }
            handleFailRes();
          });
      return completer.future;
    });
    final res = await Future.any(futures);
    token.cancel();
    return res;
  }

  Future<bool> pingHelper() async {
    try {
      final response = await dio
          .get(
            'http://$localhost:$helperPort/ping',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      return (response.data as String) == globalState.coreSHA256;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startCoreByHelper(String arg, String ipcKey) async {
    if (!await pingHelper()) return false;
    try {
      final response = await dio
          .post(
            'http://$localhost:$helperPort/start',
            data: json.encode({
              'path': appPath.corePath,
              'arg': arg,
              'key': ipcKey,
            }),
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopCoreByHelper() async {
    if (!await pingHelper()) return false;
    try {
      final response = await dio
          .post(
            'http://$localhost:$helperPort/stop',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
      return false;
    }
  }
}

final request = Request();
