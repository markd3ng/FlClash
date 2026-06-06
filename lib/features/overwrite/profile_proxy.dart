import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

String _decodeBase64(String value) {
  final normalized = base64.normalize(value.trim());
  return utf8.decode(base64.decode(normalized));
}

String _tryDecodeBase64(String value) {
  try {
    return _decodeBase64(value);
  } catch (_) {
    return value;
  }
}

String _decodeComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

int? _parsePort(Object? port) {
  if (port == null) {
    return null;
  }
  final value = port is int ? port : int.tryParse(port.toString());
  if (value == null || value <= 0 || value > 65535) {
    return null;
  }
  return value;
}

int? _uriPort(Uri uri) {
  return uri.hasPort ? uri.port : null;
}

bool _parseBool(String value) {
  final normalized = value.toLowerCase();
  return normalized == '1' || normalized == 'true';
}

List<String> _splitValues(String value) {
  return value
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

String _fallbackName(Uri uri, String scheme) {
  final fragment = _decodeComponent(uri.fragment).trim();
  if (fragment.isNotEmpty) {
    return fragment;
  }
  final host = uri.host.isNotEmpty ? uri.host : scheme;
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '$host$port';
}

void _putIfNotEmpty(Map<String, Object?> proxy, String key, Object? value) {
  if (value == null) {
    return;
  }
  if (value is String && value.isEmpty) {
    return;
  }
  if (value is Iterable && value.isEmpty) {
    return;
  }
  proxy[key] = value;
}

Map<String, Object?> _parseSimpleProxy(
  Uri uri,
  String scheme, {
  required String type,
  int? defaultPort,
}) {
  final port = _parsePort(_uriPort(uri));
  final server = uri.host;
  if (server.isEmpty || (port == null && defaultPort == null)) {
    throw FormatException('Invalid $scheme URI');
  }
  final proxy = <String, Object?>{
    'name': _fallbackName(uri, scheme),
    'type': type,
    'server': server,
    'port': port ?? defaultPort,
  };
  final userInfo = uri.userInfo;
  if (userInfo.isNotEmpty) {
    final decoded = _tryDecodeBase64(_decodeComponent(userInfo));
    final parts = decoded.split(':');
    proxy['username'] = parts.first;
    if (parts.length > 1) {
      proxy['password'] = parts.sublist(1).join(':');
    }
  }
  proxy['skip-cert-verify'] = true;
  if (scheme == 'https') {
    proxy['tls'] = true;
  }
  return proxy;
}

Map<String, Object?> _parseShadowsocks(Uri uri) {
  var nextUri = uri;
  if (!nextUri.hasPort && nextUri.host.isNotEmpty && nextUri.userInfo.isEmpty) {
    nextUri = Uri.parse('ss://${_decodeBase64(nextUri.host)}');
  }
  final port = _parsePort(_uriPort(nextUri));
  if (nextUri.host.isEmpty || port == null) {
    throw const FormatException('Invalid ss URI');
  }
  var method = _decodeComponent(nextUri.userInfo);
  String? password;
  if (method.contains(':')) {
    final parts = method.split(':');
    method = parts.first;
    password = parts.sublist(1).join(':');
  } else {
    final decoded = _tryDecodeBase64(method);
    final parts = decoded.split(':');
    if (parts.length >= 2) {
      method = parts.first;
      password = parts.sublist(1).join(':');
    }
  }
  if (method.isEmpty || password?.isNotEmpty != true) {
    throw const FormatException('Invalid ss URI');
  }
  final query = nextUri.queryParameters;
  final proxy = <String, Object?>{
    'name': _fallbackName(uri, 'ss'),
    'type': 'ss',
    'server': nextUri.host,
    'port': port,
    'cipher': method,
    'password': password,
    'udp': true,
  };
  if (query['udp-over-tcp'] == 'true' || query['uot'] == '1') {
    proxy['udp-over-tcp'] = true;
  }
  final plugin = query['plugin'] ?? '';
  if (plugin.contains(';')) {
    final pluginInfo = Uri.splitQueryString(
      'pluginName=${plugin.replaceAll(';', '&')}',
    );
    final pluginName = pluginInfo['pluginName'] ?? '';
    if (pluginName.contains('obfs')) {
      proxy['plugin'] = 'obfs';
      proxy['plugin-opts'] = {
        'mode': pluginInfo['obfs'],
        'host': pluginInfo['obfs-host'],
      };
    } else if (pluginName.contains('v2ray-plugin')) {
      proxy['plugin'] = 'v2ray-plugin';
      proxy['plugin-opts'] = {
        'mode': pluginInfo['mode'],
        'host': pluginInfo['host'],
        'path': pluginInfo['path'],
        'tls': plugin.contains('tls'),
      };
    }
  }
  return proxy;
}

Map<String, Object?> _buildTransportOptions(
  Map<String, Object?> proxy,
  String network,
  Map<String, String> query, {
  String? path,
  String? host,
}) {
  proxy['network'] = network;
  switch (network) {
    case 'ws':
    case 'httpupgrade':
      final headers = <String, Object?>{};
      _putIfNotEmpty(headers, 'Host', host ?? query['host']);
      proxy['ws-opts'] = {
        'path': path ?? query['path'] ?? '/',
        if (headers.isNotEmpty) 'headers': headers,
      };
    case 'h2':
    case 'http':
      final headers = <String, Object?>{};
      final hosts = _splitValues(host ?? query['host'] ?? '');
      if (hosts.isNotEmpty) {
        headers['Host'] = hosts;
      }
      proxy[network == 'h2' ? 'h2-opts' : 'http-opts'] = {
        'path': _splitValues(path ?? query['path'] ?? '/'),
        if (headers.isNotEmpty) 'headers': headers,
      };
    case 'grpc':
      proxy['grpc-opts'] = {
        'grpc-service-name': query['serviceName'] ?? path ?? '',
      };
  }
  return proxy;
}

Map<String, Object?> _parseVMess(String raw) {
  final body = raw.substring(raw.indexOf('://') + 3);
  try {
    final values = Map<String, Object?>.from(json.decode(_decodeBase64(body)));
    final network = (values['net'] as String?)?.toLowerCase();
    final proxy = <String, Object?>{
      'name': (values['ps'] as String?)?.trim().isNotEmpty == true
          ? values['ps']
          : 'vmess',
      'type': 'vmess',
      'server': values['add'],
      'port': int.tryParse('${values['port']}') ?? values['port'],
      'uuid': values['id'],
      'alterId': int.tryParse('${values['aid'] ?? 0}') ?? 0,
      'udp': true,
      'xudp': true,
      'tls': '${values['tls'] ?? ''}'.toLowerCase().endsWith('tls'),
      'skip-cert-verify': false,
      'cipher': (values['scy'] as String?)?.isNotEmpty == true
          ? values['scy']
          : 'auto',
    };
    _putIfNotEmpty(proxy, 'servername', values['sni']);
    final alpn = values['alpn'];
    if (alpn is String && alpn.isNotEmpty) {
      proxy['alpn'] = _splitValues(alpn);
    }
    if (network != null && network.isNotEmpty) {
      final normalizedNetwork = values['type'] == 'http'
          ? 'http'
          : network == 'http'
          ? 'h2'
          : network;
      _buildTransportOptions(
        proxy,
        normalizedNetwork,
        const {},
        path: values['path'] as String?,
        host: values['host'] as String?,
      );
    }
    return proxy;
  } catch (_) {
    final uri = Uri.parse(raw);
    final query = uri.queryParameters;
    final proxy = <String, Object?>{
      'name': _fallbackName(uri, 'vmess'),
      'type': 'vmess',
      'server': uri.host,
      'port': _parsePort(_uriPort(uri)),
      'uuid': uri.userInfo,
      'alterId': 0,
      'cipher': query['encryption']?.isNotEmpty == true
          ? query['encryption']
          : 'auto',
      'udp': true,
      'tls': query['security'] == 'tls' || query['security'] == 'reality',
    };
    _putIfNotEmpty(proxy, 'servername', query['sni']);
    _putIfNotEmpty(proxy, 'client-fingerprint', query['fp']);
    final network = (query['type'] ?? '').toLowerCase();
    if (network.isNotEmpty) {
      _buildTransportOptions(proxy, network, query);
    }
    return proxy;
  }
}

Map<String, Object?> _parseVless(Uri uri) {
  final query = uri.queryParameters;
  final proxy = <String, Object?>{
    'name': _fallbackName(uri, 'vless'),
    'type': 'vless',
    'server': uri.host,
    'port': _parsePort(_uriPort(uri)),
    'uuid': uri.userInfo,
    'udp': true,
    'tls': query['security'] == 'tls' || query['security'] == 'reality',
  };
  _putIfNotEmpty(proxy, 'flow', query['flow']);
  _putIfNotEmpty(proxy, 'encryption', query['encryption']);
  _putIfNotEmpty(proxy, 'servername', query['sni']);
  _putIfNotEmpty(proxy, 'client-fingerprint', query['fp']);
  if (query['security'] == 'reality') {
    proxy['reality-opts'] = {
      'public-key': query['pbk'],
      'short-id': query['sid'],
    };
  }
  final network = (query['type'] ?? '').toLowerCase();
  if (network.isNotEmpty) {
    _buildTransportOptions(proxy, network, query);
  }
  return proxy;
}

Map<String, Object?> _parseTrojan(Uri uri) {
  final query = uri.queryParameters;
  final proxy = <String, Object?>{
    'name': _fallbackName(uri, 'trojan'),
    'type': 'trojan',
    'server': uri.host,
    'port': _parsePort(_uriPort(uri)),
    'password': _decodeComponent(uri.userInfo),
    'udp': true,
    'skip-cert-verify': _parseBool(
      query['allowInsecure'] ?? query['insecure'] ?? '',
    ),
  };
  _putIfNotEmpty(proxy, 'sni', query['sni']);
  _putIfNotEmpty(proxy, 'client-fingerprint', query['fp'] ?? 'chrome');
  if (query['alpn']?.isNotEmpty == true) {
    proxy['alpn'] = _splitValues(query['alpn']!);
  }
  final network = (query['type'] ?? '').toLowerCase();
  if (network.isNotEmpty) {
    _buildTransportOptions(proxy, network, query);
  }
  return proxy;
}

Map<String, Object?> _parseHysteria(Uri uri) {
  final query = uri.queryParameters;
  final proxy = <String, Object?>{
    'name': _fallbackName(uri, 'hysteria'),
    'type': 'hysteria',
    'server': uri.host,
    'port': _parsePort(_uriPort(uri)),
    'sni': query['peer'] ?? query['sni'],
    'obfs': query['obfs'],
    'auth-str': query['auth'],
    'protocol': query['protocol'],
    'up': query['up'] ?? query['upmbps'],
    'down': query['down'] ?? query['downmbps'],
    'skip-cert-verify': _parseBool(query['insecure'] ?? ''),
  };
  if (query['alpn']?.isNotEmpty == true) {
    proxy['alpn'] = _splitValues(query['alpn']!);
  }
  return proxy;
}

Map<String, Object?> _parseHysteria2(Uri uri) {
  final query = uri.queryParameters;
  final proxy = <String, Object?>{
    'name': _fallbackName(uri, 'hysteria2'),
    'type': 'hysteria2',
    'server': uri.host,
    'port': _parsePort(_uriPort(uri)) ?? 443,
    'password': _decodeComponent(uri.userInfo),
    'obfs': query['obfs'],
    'obfs-password': query['obfs-password'],
    'sni': query['sni'],
    'fingerprint': query['pinSHA256'],
    'up': query['up'],
    'down': query['down'],
    'skip-cert-verify': _parseBool(query['insecure'] ?? ''),
  };
  if (query['alpn']?.isNotEmpty == true) {
    proxy['alpn'] = _splitValues(query['alpn']!);
  }
  return proxy;
}

Map<String, Object?> parseProfileProxyUri(String value) {
  final raw = value.trim();
  if (raw.isEmpty) {
    throw const FormatException('URI is empty');
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme.isEmpty) {
    throw const FormatException('Invalid URI');
  }
  final scheme = uri.scheme.toLowerCase();
  final proxy = normalizeProfileProxyMap(switch (scheme) {
    'ss' => _parseShadowsocks(uri),
    'vmess' => _parseVMess(raw),
    'trojan' => _parseTrojan(uri),
    'vless' => _parseVless(uri),
    'hysteria' => _parseHysteria(uri),
    'hysteria2' || 'hy2' => _parseHysteria2(uri),
    'http' || 'https' => _parseSimpleProxy(uri, scheme, type: 'http'),
    'socks' || 'socks5' || 'socks5h' => _parseSimpleProxy(
      uri,
      scheme,
      type: 'socks5',
      defaultPort: 1080,
    ),
    _ => throw FormatException('Unsupported URI scheme: $scheme'),
  });
  _validateProfileProxy(proxy, scheme);
  return proxy;
}

void _validateProfileProxy(Map<String, Object?> proxy, String scheme) {
  final name = proxy['name'];
  final type = proxy['type'];
  if (name is! String ||
      name.trim().isEmpty ||
      type is! String ||
      type.trim().isEmpty) {
    throw const FormatException('Invalid proxy URI');
  }
  _requireString(proxy, 'server', scheme);
  _requirePort(proxy, scheme);
  switch (type) {
    case 'ss':
      _requireString(proxy, 'cipher', scheme);
      _requireString(proxy, 'password', scheme);
    case 'vmess':
    case 'vless':
      _requireString(proxy, 'uuid', scheme);
    case 'trojan':
    case 'hysteria2':
      _requireString(proxy, 'password', scheme);
  }
}

void _requireString(Map<String, Object?> proxy, String key, String scheme) {
  final value = proxy[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid $scheme URI');
  }
}

void _requirePort(Map<String, Object?> proxy, String scheme) {
  final port = _parsePort(proxy['port']);
  if (port == null) {
    throw FormatException('Invalid $scheme URI');
  }
  proxy['port'] = port;
}

class ProfileProxyItem extends StatelessWidget {
  final bool isSelected;
  final bool isEditing;
  final ProfileProxy profileProxy;
  final VoidCallback onSelected;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;

  const ProfileProxyItem({
    super.key,
    required this.isSelected,
    required this.isEditing,
    required this.profileProxy,
    required this.onSelected,
    required this.onEdit,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        color: Colors.transparent,
        child: CommonCard(
          padding: EdgeInsets.zero,
          radius: 18,
          type: CommonCardType.filled,
          isSelected: isSelected,
          onPressed: () {
            if (isEditing) {
              onSelected();
              return;
            }
            onEdit();
          },
          child: ListTile(
            minTileHeight: 32 + globalState.measure.bodyMediumHeight,
            minVerticalPadding: 12,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(
              profileProxy.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodyMedium?.toJetBrainsMono,
            ),
            subtitle: Text(
              profileProxy.type,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colorScheme.onSurfaceVariant.opacity80,
              ),
            ),
            trailing: isEditing
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: CommonCheckBox(
                      value: isSelected,
                      isCircle: true,
                      onChanged: (_) {
                        onSelected();
                      },
                    ),
                  )
                : Switch(value: profileProxy.enable, onChanged: onToggle),
          ),
        ),
      ),
    );
  }
}

class ProfileProxyEditView extends StatefulWidget {
  final ProfileProxy? profileProxy;

  const ProfileProxyEditView({super.key, this.profileProxy});

  @override
  State<ProfileProxyEditView> createState() => _ProfileProxyEditViewState();
}

class _ProfileProxyEditViewState extends State<ProfileProxyEditView> {
  final _uriController = TextEditingController();
  late bool _enable;

  @override
  void initState() {
    super.initState();
    final profileProxy = widget.profileProxy;
    _uriController.text = profileProxy?.uri ?? '';
    _enable = profileProxy?.enable ?? true;
  }

  @override
  void dispose() {
    _uriController.dispose();
    super.dispose();
  }

  void _handleSubmit() {
    try {
      final uri = _uriController.text.trim();
      final proxy = parseProfileProxyUri(uri);
      final nextProfileProxy =
          (widget.profileProxy ?? ProfileProxy.create(uri: uri, proxy: proxy))
              .copyWith(enable: _enable, uri: uri, proxy: proxy);
      Navigator.of(context).pop(nextProfileProxy);
    } catch (e) {
      context.showNotifier(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: appLocalizations.proxies,
      actions: [
        CommonMinIconButtonTheme(
          child: IconButton.filledTonal(
            onPressed: _handleSubmit,
            icon: Icon(Icons.check),
          ),
        ),
        SizedBox(width: 8),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _uriController,
            minLines: 4,
            maxLines: 8,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'URI',
            ),
          ),
          SizedBox(height: 12),
          CommonCard(
            padding: EdgeInsets.zero,
            type: CommonCardType.filled,
            radius: 18,
            child: SwitchListTile(
              value: _enable,
              title: Text(appLocalizations.enableOverride),
              onChanged: (value) {
                setState(() {
                  _enable = value;
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileProxiesContent extends ConsumerStatefulWidget {
  final int profileId;

  const ProfileProxiesContent({super.key, required this.profileId});

  @override
  ConsumerState<ProfileProxiesContent> createState() =>
      _ProfileProxiesContentState();
}

class _ProfileProxiesContentState extends ConsumerState<ProfileProxiesContent> {
  final _profileProxyKey = utils.id;

  Future<void> _handleAddOrUpdateProfileProxy([
    ProfileProxy? profileProxy,
  ]) async {
    final res = await BaseNavigator.push<ProfileProxy>(
      context,
      ProfileProxyEditView(profileProxy: profileProxy),
    );
    if (res == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    final profileProxies =
        ref.read(profileProvider(widget.profileId))?.profileProxies ?? [];
    final name = res.name;
    final hasDuplicate = profileProxies.any((item) {
      return item.id != res.id && item.name == name;
    });
    if (hasDuplicate) {
      context.showNotifier(
        appLocalizations.existsTip(appLocalizations.proxies),
      );
      return;
    }
    _putProfileProxy(res);
  }

  void _putProfileProxy(ProfileProxy profileProxy) {
    ref.read(profilesProvider.notifier).updateProfile(widget.profileId, (
      state,
    ) {
      return state.copyWith(
        profileProxies: state.profileProxies.copyAndPut(profileProxy),
      );
    });
  }

  void _handleProfileProxySelected(int profileProxyId) {
    ref.read(selectedItemsProvider(_profileProxyKey).notifier).update((
      selectedProfileProxies,
    ) {
      final nextProfileProxies = Set<int>.from(selectedProfileProxies)
        ..addOrRemove(profileProxyId);
      return nextProfileProxies;
    });
  }

  void _handleSelectAllProfileProxies() {
    final ids =
        ref
            .read(profileProvider(widget.profileId))
            ?.profileProxies
            .map((item) => item.id)
            .toSet() ??
        {};
    ref.read(selectedItemsProvider(_profileProxyKey).notifier).update((
      selected,
    ) {
      return selected.containsAll(ids) ? {} : ids;
    });
  }

  Future<void> _handleDeleteProfileProxies() async {
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(
        text: appLocalizations.deleteMultipTip(appLocalizations.proxies),
      ),
    );
    if (res != true) {
      return;
    }
    final selectedProfileProxies = ref.read(
      selectedItemsProvider(_profileProxyKey),
    );
    ref.read(profilesProvider.notifier).updateProfile(widget.profileId, (
      state,
    ) {
      final deletedNames = state.profileProxies
          .where((item) => selectedProfileProxies.contains(item.id))
          .map((item) => item.name)
          .toSet();
      return state.copyWith(
        profileProxies: state.profileProxies
            .where((item) => !selectedProfileProxies.contains(item.id))
            .toList(),
        proxyChains: state.proxyChains
            .map(
              (chain) => chain.copyWith(
                proxies: chain.proxies
                    .where((proxy) => !deletedNames.contains(proxy))
                    .toList(),
              ),
            )
            .toList(),
      );
    });
    ref.read(selectedItemsProvider(_profileProxyKey).notifier).value = {};
  }

  void _handleProfileProxyToggle(ProfileProxy profileProxy, bool value) {
    _putProfileProxy(profileProxy.copyWith(enable: value));
  }

  @override
  Widget build(BuildContext context) {
    final profileProxies =
        ref.watch(profileProvider(widget.profileId))?.profileProxies ?? [];
    final selectedProfileProxies = ref.watch(
      selectedItemsProvider(_profileProxyKey),
    );
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: SizedBox(height: 24)),
        SliverToBoxAdapter(
          child: InfoHeader(
            info: Info(label: appLocalizations.proxies),
            actions: [
              if (selectedProfileProxies.isNotEmpty) ...[
                CommonMinIconButtonTheme(
                  child: IconButton.filledTonal(
                    onPressed: _handleDeleteProfileProxies,
                    icon: Icon(Icons.delete),
                  ),
                ),
                SizedBox(width: 8),
              ],
              CommonMinFilledButtonTheme(
                child: selectedProfileProxies.isNotEmpty
                    ? FilledButton(
                        onPressed: _handleSelectAllProfileProxies,
                        child: Text(appLocalizations.selectAll),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: () {
                          _handleAddOrUpdateProfileProxy();
                        },
                        icon: Icon(Icons.add),
                        label: Text(appLocalizations.add),
                      ),
              ),
            ],
          ),
        ),
        if (profileProxies.isNotEmpty) ...[
          SliverToBoxAdapter(child: SizedBox(height: 8)),
          SliverList.builder(
            itemCount: profileProxies.length,
            itemBuilder: (_, index) {
              final profileProxy = profileProxies[index];
              return ProfileProxyItem(
                isEditing: selectedProfileProxies.isNotEmpty,
                isSelected: selectedProfileProxies.contains(profileProxy.id),
                profileProxy: profileProxy,
                onSelected: () {
                  _handleProfileProxySelected(profileProxy.id);
                },
                onEdit: () {
                  _handleAddOrUpdateProfileProxy(profileProxy);
                },
                onToggle: (value) {
                  _handleProfileProxyToggle(profileProxy, value);
                },
              );
            },
          ),
        ],
      ],
    );
  }
}
