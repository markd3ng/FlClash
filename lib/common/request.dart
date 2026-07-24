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

class AppUpdateInfo {
  const AppUpdateInfo({this.releaseNotes});

  final String? releaseNotes;
}

final _releaseVersionPattern = RegExp(
  r'^v?(\d+(?:\.\d+)+(?:[-+][\w.-]+)?)$',
  caseSensitive: false,
);
final _releasePlaceholderPattern = RegExp(
  r'^(?:(?:feat|chore)(?:\([^)]*\))?:\s*)?(?:release|follow upstream)\s+v?\d+(?:\.\d+)+(?:[-+][\w.-]+)?$',
  caseSensitive: false,
);
final _releaseHeadingPattern = RegExp(
  r'^##\s+(v?\d+(?:\.\d+)+(?:[-+][\w.-]+)?)\s*$',
  caseSensitive: false,
);

String? normalizeReleaseTagName(String? value) {
  if (value == null) return null;
  final match = _releaseVersionPattern.firstMatch(value.trim());
  return match == null ? null : 'v${match.group(1)}';
}

String? releaseTagNameFromVersionData(Object? versionData) {
  if (versionData is String) {
    return normalizeReleaseTagName(versionData.split('+').first);
  }
  if (versionData is! Map<String, dynamic>) return null;
  for (final key in [
    'tag_name',
    'tagName',
    'version_name',
    'versionName',
    'version',
  ]) {
    final value = versionData[key];
    if (value is! String) continue;
    final tagName = normalizeReleaseTagName(value.split('+').first);
    if (tagName != null) return tagName;
  }
  return null;
}

String? latestReleaseTagNameFromChangelog(String source) {
  for (final line in source.replaceAll('\r\n', '\n').split('\n')) {
    final match = _releaseHeadingPattern.firstMatch(line.trim());
    if (match != null) return normalizeReleaseTagName(match.group(1));
  }
  return null;
}

String? normalizeReleaseNotes(String? source) {
  if (source == null) return null;
  final normalized = <String>[];
  var pendingEmptyLine = false;
  for (final rawLine in source.replaceAll('\r\n', '\n').split('\n')) {
    var line = rawLine.trimRight();
    final releaseLine = line
        .trim()
        .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
        .replaceFirst(RegExp(r'^-\s+'), '');
    if (_releaseVersionPattern.hasMatch(releaseLine) ||
        _releasePlaceholderPattern.hasMatch(releaseLine)) {
      continue;
    }
    line = line.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
    line = line.replaceAllMapped(
      RegExp(r'\[([^\]]+)]\([^)]+\)'),
      (match) => match.group(1)!,
    );
    line = line.replaceAll('**', '').replaceAll('`', '');
    final isEmpty = line.trim().isEmpty;
    if (isEmpty) {
      pendingEmptyLine = normalized.isNotEmpty;
      continue;
    }
    if (pendingEmptyLine &&
        !(normalized.last.trimLeft().startsWith('- ') &&
            line.trimLeft().startsWith('- '))) {
      normalized.add('');
    }
    normalized.add(line);
    pendingEmptyLine = false;
  }
  final result = normalized.join('\n').trim();
  return result.isEmpty ? null : result;
}

String? extractCurrentReleaseNotes(String? source, String tagName) {
  if (source == null) return null;
  final versionNotes = extractReleaseNotesFromChangelog(source, tagName);
  if (versionNotes != null) return versionNotes;
  if (RegExp(r'^##\s+', multiLine: true).hasMatch(source)) return null;
  return normalizeReleaseNotes(source);
}

String? extractEmbeddedReleaseNotes(Object? versionData, String tagName) {
  if (versionData is! Map<String, dynamic>) return null;
  for (final key in ['changelog', 'release_notes', 'releaseNotes']) {
    final notes = versionData[key];
    if (notes is String) {
      final normalized = extractCurrentReleaseNotes(
        notes,
        latestReleaseTagNameFromChangelog(notes) ?? tagName,
      );
      if (normalized != null) return normalized;
    }
  }
  return null;
}

String? extractReleaseNotesFromReleaseBody(String? body, String tagName) {
  if (body == null) return null;
  var end = body.length;
  for (final marker in [
    '<div align=center>',
    '<div align="center">',
    '**Download based on your OS:**',
    '**List of all changes:**',
  ]) {
    final index = body.indexOf(marker);
    if (index >= 0 && index < end) end = index;
  }
  final notes = body.substring(0, end);
  return extractCurrentReleaseNotes(notes, tagName);
}

String? extractReleaseNotesFromChangelog(String source, String tagName) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final normalizedTagName = normalizeReleaseTagName(tagName);
  if (normalizedTagName == null) return null;
  final start = lines.indexWhere((line) {
    final match = _releaseHeadingPattern.firstMatch(line.trim());
    return match != null &&
        normalizeReleaseTagName(match.group(1)) == normalizedTagName;
  });
  if (start < 0) return null;
  var end = lines.length;
  for (var index = start + 1; index < lines.length; index++) {
    if (lines[index].trimLeft().startsWith('## ')) {
      end = index;
      break;
    }
  }
  return normalizeReleaseNotes(lines.sublist(start + 1, end).join('\n'));
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

  Future<AppUpdateInfo?> checkForUpdate() async {
    for (final domain in Secrets.apiDomains) {
      try {
        final response = await _apiDirectDio.get(
          'https://$domain/api/v1/version/get',
          queryParameters: {
            't': DateTime.now().millisecondsSinceEpoch.toString(),
          },
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

        final tagName =
            releaseTagNameFromVersionData(versionData) ??
            'v${globalState.packageInfo.version.trim()}';
        final releaseNotes =
            extractEmbeddedReleaseNotes(versionData, tagName) ??
            await _fetchReleaseNotes(tagName);
        return AppUpdateInfo(releaseNotes: releaseNotes);
      } catch (_) {
        commonPrint.log(
          'checkForUpdate failed for $domain',
          logLevel: LogLevel.warning,
        );
      }
    }
    throw Exception('checkForUpdate failed for all domains');
  }

  Future<String?> _fetchReleaseNotes(String tagName) async {
    final releaseFuture = _fetchLatestGitHubRelease();
    final changelogFuture = _fetchGitHubChangelog();
    final release = await releaseFuture;
    final changelog = await changelogFuture;
    final currentTagName =
        release?.tagName ??
        (changelog == null
            ? null
            : latestReleaseTagNameFromChangelog(changelog)) ??
        tagName;
    return extractReleaseNotesFromReleaseBody(release?.body, currentTagName) ??
        (changelog == null
            ? null
            : extractReleaseNotesFromChangelog(changelog, currentTagName));
  }

  Future<({String? body, String tagName})?> _fetchLatestGitHubRelease() async {
    try {
      final response = await _apiDirectDio
          .get<Map<String, dynamic>>(
            'https://api.github.com/repos/$releaseRepository/releases/latest',
            options: Options(responseType: ResponseType.json),
          )
          .timeout(httpTimeoutDuration);
      final data = response.data;
      final tagName = normalizeReleaseTagName(data?['tag_name'] as String?);
      if (tagName == null) return null;
      return (body: data?['body'] as String?, tagName: tagName);
    } catch (error) {
      commonPrint.log(
        'fetch release notes failed: $error',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<String?> _fetchGitHubChangelog() async {
    try {
      final response = await _apiDirectDio
          .get<String>(
            'https://raw.githubusercontent.com/$releaseRepository/main/CHANGELOG.md',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(httpTimeoutDuration);
      return response.data;
    } catch (error) {
      commonPrint.log(
        'fetch changelog failed: $error',
        logLevel: LogLevel.warning,
      );
      return null;
    }
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
