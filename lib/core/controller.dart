import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/services/config_key_store.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';

class ConfigValidationException implements Exception {
  final String message;

  const ConfigValidationException(this.message);

  @override
  String toString() => message;
}

class CoreController {
  static CoreController? _instance;
  late CoreHandlerInterface _interface;
  final Map<String, Future<String>> _geoUpdates = {};

  CoreController._internal() {
    if (system.isAndroid) {
      _interface = coreLib!;
    } else {
      _interface = coreService!;
    }
  }

  factory CoreController() {
    _instance ??= CoreController._internal();
    return _instance!;
  }

  bool get isCompleted => _interface.completer.isCompleted;

  Future<String> preload() {
    return _interface.preload();
  }

  static Future<void> initGeo() async {
    final homePath = await appPath.homeDirPath;
    final homeDir = Directory(homePath);
    final isExists = await homeDir.exists();
    if (!isExists) {
      await homeDir.create(recursive: true);
    }
    const geoFileNameList = [MMDB, GEOIP, GEOSITE, ASN];
    try {
      for (final geoFileName in geoFileNameList) {
        final geoFile = File(join(homePath, geoFileName));
        final isExists = await geoFile.exists();
        if (isExists) {
          continue;
        }
        final data = await rootBundle.load('assets/data/$geoFileName');
        List<int> bytes = data.buffer.asUint8List();
        await geoFile.writeAsBytes(bytes, flush: true);
      }
    } catch (e) {
      exit(0);
    }
  }

  Future<bool> init(int version) async {
    await initGeo();
    final homeDirPath = await appPath.homeDirPath;
    final configAgeSecretKey = await ConfigKeyStore.seedBase64();
    return await _interface.init(
      InitParams(
        homeDir: homeDirPath,
        version: version,
        profileKey: Secrets.profileKey,
        configAgeSecretKey: configAgeSecretKey,
      ),
    );
  }

  Future<bool> shutdown(bool isUser) async {
    return _interface.shutdown(isUser);
  }

  FutureOr<bool> get isInit => _interface.isInit;

  Future<String> validateConfig(String path) async {
    final res = await _interface.validateConfig(path);
    return res;
  }

  Future<String> validateConfigWithBytes(String data) async {
    final res = await _interface.validateConfigWithBytes(data);
    return res;
  }

  Future<String> validateConfigWithData(String data) async {
    final path = await appPath.tempFilePath;
    final file = File(path);
    await file.safeWriteAsString(data);
    final res = await _interface.validateConfig(path);
    await File(path).safeDelete();
    return res;
  }

  Future<String> updateConfig(UpdateParams updateParams) async {
    return await _interface.updateConfig(updateParams);
  }

  Future<String> setupConfig({
    required SetupParams params,
    FutureOr<void> Function()? preloadInvoke,
  }) async {
    if (system.isAndroid) {
      final res = _interface.setupConfig(params);
      if (preloadInvoke != null) {
        await preloadInvoke();
      }
      return res;
    }
    final res = await _interface.setupConfig(params);
    if (res.isEmpty && preloadInvoke != null) {
      await preloadInvoke();
    }
    return res;
  }

  Future<List<Group>> getProxiesGroups({
    required ProxiesSortType sortType,
    required DelayMap delayMap,
    required Map<String, String> selectedMap,
    required String defaultTestUrl,
  }) async {
    final proxiesData = await _interface.getProxies();
    return toGroupsTask(
      ComputeGroupsState(
        proxiesData: proxiesData,
        sortType: sortType,
        delayMap: delayMap,
        selectedMap: selectedMap,
        defaultTestUrl: defaultTestUrl,
      ),
    );
  }

  Future<void> changeProxy(ChangeProxyParams changeProxyParams) async {
    final message = await _interface.changeProxy(changeProxyParams);
    if (message.isNotEmpty) {
      throw message;
    }
  }

  Future<List<TrackerInfo>> getConnections() async {
    final res = await _interface.getConnections();
    final connectionsData = json.decode(res) as Map;
    final connectionsRaw = connectionsData['connections'] as List? ?? [];
    return connectionsRaw.map((e) => TrackerInfo.fromJson(e)).toList();
  }

  void closeConnection(String id) {
    _interface.closeConnection(id);
  }

  void closeConnections() {
    _interface.closeConnections();
  }

  void resetConnections() {
    _interface.resetConnections();
  }

  Future<List<ExternalProvider>> getExternalProviders() async {
    final externalProvidersRawString = await _interface.getExternalProviders();
    if (externalProvidersRawString.isEmpty) {
      return [];
    }
    final externalProviders =
        (await externalProvidersRawString.commonToJSON<List<dynamic>>())
            .map((item) => ExternalProvider.fromJson(item))
            .toList();
    return externalProviders;
  }

  Future<ExternalProvider?> getExternalProvider(
    String externalProviderName,
  ) async {
    final externalProvidersRawString = await _interface.getExternalProvider(
      externalProviderName,
    );
    if (externalProvidersRawString.isEmpty) {
      return null;
    }
    return ExternalProvider.fromJson(json.decode(externalProvidersRawString));
  }

  Future<String> updateGeoData(UpdateGeoDataParams params) {
    final key = '${params.geoType}:${params.geoName}';
    return _geoUpdates[key] ??= _interface
        .updateGeoData(params)
        .whenComplete(() => _geoUpdates.remove(key));
  }

  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  }) {
    return _interface.sideLoadExternalProvider(
      providerName: providerName,
      data: data,
    );
  }

  Future<String> updateExternalProvider({required String providerName}) async {
    return _interface.updateExternalProvider(providerName);
  }

  Future<bool> startListener() async {
    return await _interface.startListener();
  }

  Future<bool> stopListener() async {
    return await _interface.stopListener();
  }

  Future<Delay> getDelay(String url, String proxyName) async {
    final testUrl = getDelayTestUrl(proxyName: proxyName, testUrl: url);
    final data = await _interface.asyncTestDelay(testUrl, proxyName);
    return Delay.fromJson(json.decode(data));
  }

  Future<Map<String, dynamic>> getConfig(String path) async {
    final res = await _interface.getConfig(path);
    if (res.isSuccess) {
      return normalizeCoreRawConfig(Map<String, dynamic>.from(res.data));
    } else {
      throw res.message;
    }
  }

  Future<Map<String, dynamic>> getConfigFromBytes(String dataStr) async {
    final res = await _interface.getConfigFromBytes(dataStr);
    if (res.isSuccess) {
      return normalizeCoreRawConfig(Map<String, dynamic>.from(res.data));
    } else {
      throw res.message;
    }
  }

  Future<Traffic> getTraffic(bool onlyStatisticsProxy) async {
    final trafficString = await _interface.getTraffic(onlyStatisticsProxy);
    if (trafficString.isEmpty) {
      return Traffic();
    }
    return Traffic.fromJson(json.decode(trafficString));
  }

  Future<IpInfo?> getCountryCode(String ip) async {
    final countryCode = await _interface.getCountryCode(ip);
    if (countryCode.isEmpty) {
      return null;
    }
    return IpInfo(ip: ip, countryCode: countryCode);
  }

  Future<Traffic> getTotalTraffic(bool onlyStatisticsProxy) async {
    final totalTrafficString = await _interface.getTotalTraffic(
      onlyStatisticsProxy,
    );
    if (totalTrafficString.isEmpty) {
      return Traffic();
    }
    return Traffic.fromJson(json.decode(totalTrafficString));
  }

  Future<int> getMemory() async {
    final value = await _interface.getMemory();
    if (value.isEmpty) {
      return 0;
    }
    return int.parse(value);
  }

  void resetTraffic() {
    _interface.resetTraffic();
  }

  void startLog() {
    _interface.startLog();
  }

  void stopLog() {
    _interface.stopLog();
  }

  Future<void> requestGc() async {
    await _interface.forceGc();
  }

  Future<void> destroy() async {
    await _interface.destroy();
  }

  Future<void> crash() async {
    await _interface.crash();
  }

  Future<String> deleteFile(String path) async {
    return await _interface.deleteFile(path);
  }
}

Map<String, dynamic> normalizeCoreRawConfig(Map<String, dynamic> data) {
  final normalized = Map<String, dynamic>.from(data);
  if (normalized.containsKey('rule')) {
    normalized['rules'] = normalized.remove('rule');
  }
  final tunnels = normalized['tunnels'];
  if (tunnels is List) {
    normalized['tunnels'] = tunnels.map((value) {
      if (value is! Map) return value;
      final tunnel = Map<String, dynamic>.from(value);
      for (final (jsonKey, yamlKey) in const [
        ('Network', 'network'),
        ('Address', 'address'),
        ('Target', 'target'),
        ('Proxy', 'proxy'),
      ]) {
        if (tunnel.containsKey(jsonKey) && !tunnel.containsKey(yamlKey)) {
          tunnel[yamlKey] = tunnel.remove(jsonKey);
        }
      }
      return tunnel;
    }).toList();
  }
  return normalized;
}

final coreController = CoreController();
