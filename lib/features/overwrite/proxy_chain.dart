import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/overwrite/profile_proxy.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _virtualProxyTypes = {
  'Selector',
  'URLTest',
  'Fallback',
  'LoadBalance',
  'Relay',
  'Direct',
  'Reject',
  'RejectDrop',
  'Compatible',
  'Pass',
  'Dns',
};

class ProxyChainCandidateSection {
  final String label;
  final IconData iconData;
  final List<String> proxies;

  const ProxyChainCandidateSection({
    required this.label,
    required this.iconData,
    required this.proxies,
  });
}

List<String> _addUniqueProxyNames(Set<String> seen, Iterable<String> proxies) {
  final names = <String>[];
  for (final proxy in normalizeProxyChainProxies(proxies)) {
    if (seen.add(proxy)) {
      names.add(proxy);
    }
  }
  return names;
}

List<ProxyChainCandidateSection> buildProxyChainCandidateSections({
  required List<Group> groups,
  required List<ExternalProvider> providers,
  Iterable<ProfileProxy> profileProxies = const [],
  Iterable<String> extra = const [],
}) {
  final sections = <ProxyChainCandidateSection>[];
  final seen = <String>{};

  void addSection({
    required String label,
    required IconData iconData,
    required Iterable<String> proxies,
  }) {
    final names = _addUniqueProxyNames(seen, proxies);
    if (names.isEmpty) {
      return;
    }
    sections.add(
      ProxyChainCandidateSection(
        label: label,
        iconData: iconData,
        proxies: names,
      ),
    );
  }

  addSection(
    label: appLocalizations.proxyChainCustomNodes,
    iconData: Icons.add_link,
    proxies: profileProxies.where((item) => item.isValid).map((item) {
      return item.name;
    }),
  );

  for (final group in groups) {
    addSection(
      label: group.name,
      iconData: Icons.account_tree_outlined,
      proxies: group.all
          .where((proxy) {
            return !_virtualProxyTypes.contains(proxy.type);
          })
          .map((proxy) {
            return proxy.name;
          }),
    );
  }

  addSection(
    label: appLocalizations.proxyChainProviderNodes,
    iconData: Icons.hub_outlined,
    proxies: providers.where((item) => item.type == 'Proxy').map((item) {
      return item.name;
    }),
  );

  addSection(
    label: appLocalizations.proxyChainOtherNodes,
    iconData: Icons.more_horiz,
    proxies: extra,
  );

  return sections;
}

Color _getProxyChainRoleColor(
  BuildContext context,
  int index,
  int totalLength,
) {
  if (index == 0) {
    return Colors.green;
  }
  if (index == totalLength - 1 && totalLength > 1) {
    return Colors.orange;
  }
  return context.colorScheme.primary;
}

String _getProxyChainRoleLabel(int index, int totalLength) {
  if (index == 0) {
    return appLocalizations.proxyChainEntry;
  }
  if (index == totalLength - 1 && totalLength > 1) {
    return appLocalizations.proxyChainExit;
  }
  return '${index + 1}';
}

class ProxyChainRoleBadge extends StatelessWidget {
  final int index;
  final int totalLength;

  const ProxyChainRoleBadge({
    super.key,
    required this.index,
    required this.totalLength,
  });

  @override
  Widget build(BuildContext context) {
    final color = _getProxyChainRoleColor(context, index, totalLength);
    return Container(
      constraints: BoxConstraints(minWidth: 42),
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _getProxyChainRoleLabel(index, totalLength),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.labelSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class ProxyChainItem extends StatelessWidget {
  final bool isSelected;
  final bool isEditing;
  final ProxyChain proxyChain;
  final VoidCallback onSelected;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;

  const ProxyChainItem({
    super.key,
    required this.isSelected,
    required this.isEditing,
    required this.proxyChain,
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
              proxyChain.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodyMedium?.toJetBrainsMono,
            ),
            subtitle: proxyChain.proxies.isNotEmpty
                ? Text(
                    proxyChain.proxies.join('  ->  '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: context.colorScheme.onSurfaceVariant.opacity80,
                    ),
                  )
                : null,
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
                : Switch(value: proxyChain.enable, onChanged: onToggle),
          ),
        ),
      ),
    );
  }
}

class ProfileProxyChainsView extends StatefulWidget {
  final int profileId;

  const ProfileProxyChainsView({super.key, required this.profileId});

  @override
  State<ProfileProxyChainsView> createState() => _ProfileProxyChainsViewState();
}

class _ProfileProxyChainsViewState extends State<ProfileProxyChainsView> {
  @override
  void dispose() {
    super.dispose();
    appController.autoApplyProfile();
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: appLocalizations.proxyChains,
      body: CustomScrollView(
        slivers: [
          ProfileProxyChainsContent(
            profileId: widget.profileId,
            showEmptyStatus: true,
            handlePop: true,
          ),
        ],
      ),
    );
  }
}

class ProfileProxyChainsContent extends ConsumerStatefulWidget {
  final int profileId;
  final bool showEmptyStatus;
  final bool handlePop;

  const ProfileProxyChainsContent({
    super.key,
    required this.profileId,
    this.showEmptyStatus = false,
    this.handlePop = false,
  });

  @override
  ConsumerState<ProfileProxyChainsContent> createState() =>
      _ProfileProxyChainsContentState();
}

class _ProfileProxyChainsContentState
    extends ConsumerState<ProfileProxyChainsContent> {
  final _proxyChainKey = utils.id;

  Future<void> _handleAddOrUpdateProxyChain([ProxyChain? proxyChain]) async {
    final groups = ref.read(groupsProvider);
    final providers = ref.read(providersProvider);
    final profileProxies =
        ref.read(profileProvider(widget.profileId))?.profileProxies ?? [];
    final candidateSections = buildProxyChainCandidateSections(
      groups: groups,
      providers: providers,
      profileProxies: profileProxies,
      extra: proxyChain?.proxies ?? [],
    );
    final res = await BaseNavigator.push<ProxyChain>(
      context,
      ProxyChainEditView(
        proxyChain: proxyChain,
        candidateSections: candidateSections,
      ),
    );
    if (res == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    _putProxyChain(res);
    appController.applyProfileDebounce(silence: true);
    context.showNotifier(appLocalizations.proxyChainSavedAndApplied);
  }

  void _putProxyChain(ProxyChain proxyChain) {
    ref.read(profilesProvider.notifier).updateProfile(widget.profileId, (
      state,
    ) {
      return state.copyWith(
        proxyChains: state.proxyChains.copyAndPut(proxyChain),
      );
    });
  }

  void _handleProxyChainSelected(int proxyChainId) {
    ref.read(selectedItemsProvider(_proxyChainKey).notifier).update((
      selectedProxyChains,
    ) {
      final nextProxyChains = Set<int>.from(selectedProxyChains)
        ..addOrRemove(proxyChainId);
      return nextProxyChains;
    });
  }

  void _handleSelectAllProxyChains() {
    final ids =
        ref
            .read(profileProvider(widget.profileId))
            ?.proxyChains
            .map((item) => item.id)
            .toSet() ??
        {};
    ref.read(selectedItemsProvider(_proxyChainKey).notifier).update((selected) {
      return selected.containsAll(ids) ? {} : ids;
    });
  }

  Future<void> _handleDeleteProxyChains() async {
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(
        text: appLocalizations.deleteMultipTip(appLocalizations.proxyChains),
      ),
    );
    if (res != true) {
      return;
    }
    final selectedProxyChains = ref.read(selectedItemsProvider(_proxyChainKey));
    ref.read(profilesProvider.notifier).updateProfile(widget.profileId, (
      state,
    ) {
      return state.copyWith(
        proxyChains: state.proxyChains
            .where((item) => !selectedProxyChains.contains(item.id))
            .toList(),
      );
    });
    ref.read(selectedItemsProvider(_proxyChainKey).notifier).value = {};
  }

  void _handleProxyChainToggle(ProxyChain proxyChain, bool value) {
    _putProxyChain(proxyChain.copyWith(enable: value));
  }

  void _handleProxyChainReorder(int oldIndex, int newIndex) {
    ref.read(profilesProvider.notifier).updateProfile(widget.profileId, (
      state,
    ) {
      return state.copyWith(
        proxyChains: state.proxyChains.copyAndReorder(oldIndex, newIndex),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final proxyChains =
        ref.watch(profileProvider(widget.profileId))?.proxyChains ?? [];
    final selectedProxyChains = ref.watch(
      selectedItemsProvider(_proxyChainKey),
    );
    final child = SliverMainAxisGroup(
      slivers: [
        ProfileProxiesContent(profileId: widget.profileId),
        SliverToBoxAdapter(child: SizedBox(height: 24)),
        SliverToBoxAdapter(
          child: InfoHeader(
            info: Info(label: appLocalizations.proxyChains),
            actions: [
              if (selectedProxyChains.isNotEmpty) ...[
                CommonMinIconButtonTheme(
                  child: IconButton.filledTonal(
                    onPressed: _handleDeleteProxyChains,
                    icon: Icon(Icons.delete),
                  ),
                ),
                SizedBox(width: 8),
              ],
              CommonMinFilledButtonTheme(
                child: selectedProxyChains.isNotEmpty
                    ? FilledButton(
                        onPressed: _handleSelectAllProxyChains,
                        child: Text(appLocalizations.selectAll),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: () {
                          _handleAddOrUpdateProxyChain();
                        },
                        icon: Icon(Icons.add),
                        label: Text(appLocalizations.add),
                      ),
              ),
            ],
          ),
        ),
        if (proxyChains.isNotEmpty) ...[
          SliverToBoxAdapter(child: SizedBox(height: 8)),
          SliverReorderableList(
            itemCount: proxyChains.length,
            itemBuilder: (_, index) {
              final proxyChain = proxyChains[index];
              return ReorderableDelayedDragStartListener(
                key: ObjectKey(proxyChain),
                index: index,
                child: ProxyChainItem(
                  isEditing: selectedProxyChains.isNotEmpty,
                  isSelected: selectedProxyChains.contains(proxyChain.id),
                  proxyChain: proxyChain,
                  onSelected: () {
                    _handleProxyChainSelected(proxyChain.id);
                  },
                  onEdit: () {
                    _handleAddOrUpdateProxyChain(proxyChain);
                  },
                  onToggle: (value) {
                    _handleProxyChainToggle(proxyChain, value);
                  },
                ),
              );
            },
            onReorder: _handleProxyChainReorder,
          ),
        ] else if (widget.showEmptyStatus)
          SliverFillRemaining(
            hasScrollBody: false,
            child: NullStatus(
              label: appLocalizations.nullTip(appLocalizations.proxyChains),
            ),
          ),
      ],
    );
    if (!widget.handlePop) {
      return child;
    }
    return CommonPopScope(
      onPop: (_) {
        if (selectedProxyChains.isNotEmpty) {
          ref.read(selectedItemsProvider(_proxyChainKey).notifier).value = {};
          return false;
        }
        Navigator.of(context).pop();
        return false;
      },
      child: child,
    );
  }
}

class ProxyChainEditView extends ConsumerStatefulWidget {
  final ProxyChain? proxyChain;
  final List<ProxyChainCandidateSection> candidateSections;

  const ProxyChainEditView({
    super.key,
    this.proxyChain,
    required this.candidateSections,
  });

  @override
  ConsumerState<ProxyChainEditView> createState() => _ProxyChainEditViewState();
}

class _ProxyChainEditViewState extends ConsumerState<ProxyChainEditView> {
  final _nameController = TextEditingController();
  final _proxyController = TextEditingController();
  List<String> _proxies = [];
  late bool _enable;

  @override
  void initState() {
    super.initState();
    final proxyChain = widget.proxyChain;
    _nameController.text = proxyChain?.name ?? '';
    _proxies = List<String>.from(proxyChain?.proxies ?? []);
    _enable = proxyChain?.enable ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _proxyController.dispose();
    super.dispose();
  }

  void _handleAdd(String value) {
    final proxyName = value.trim();
    if (proxyName.isEmpty) {
      return;
    }
    if (normalizeProxyChainProxies(_proxies).contains(proxyName)) {
      context.showNotifier(
        appLocalizations.existsTip(appLocalizations.proxies),
      );
      return;
    }
    _proxies = [..._proxies, proxyName];
    _proxyController.clear();
    setState(() {});
  }

  void _handleDelete(String value) {
    _proxies = _proxies.where((item) => item != value).toList();
    setState(() {});
  }

  void _handleClear() {
    _proxies = [];
    setState(() {});
  }

  void _handleReorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final proxies = List<String>.from(_proxies);
    final proxy = proxies.removeAt(oldIndex);
    proxies.insert(newIndex, proxy);
    _proxies = proxies;
    setState(() {});
  }

  void _handleSubmit() {
    final proxies = normalizeProxyChainProxies(_proxies);
    if (proxies.length < 2) {
      context.showNotifier(appLocalizations.proxyChainMinimumNodes);
      return;
    }
    if (proxies.toSet().length != proxies.length) {
      context.showNotifier(
        appLocalizations.existsTip(appLocalizations.proxies),
      );
      return;
    }
    final proxyChain = (widget.proxyChain ?? ProxyChain.create()).copyWith(
      enable: _enable,
      name: _nameController.text.trim(),
      proxies: proxies,
    );
    Navigator.of(context).pop(proxyChain);
  }

  Widget _buildProxyItem({
    required String proxy,
    required int index,
    required int totalLength,
    bool isDecorator = false,
  }) {
    return ReorderableDelayedDragStartListener(
      key: ValueKey(proxy),
      index: index,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CommonCard(
            padding: EdgeInsets.zero,
            radius: 18,
            type: CommonCardType.filled,
            child: ListTile(
              minTileHeight: 32 + globalState.measure.bodyMediumHeight,
              minVerticalPadding: 12,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: ProxyChainRoleBadge(
                index: index,
                totalLength: totalLength,
              ),
              title: Text(
                proxy,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.bodyMedium?.toJetBrainsMono,
              ),
              subtitle: Text(
                index == 0
                    ? appLocalizations.proxyChainEntry
                    : index == totalLength - 1 && totalLength > 1
                    ? appLocalizations.proxyChainExit
                    : appLocalizations.proxyChains,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colorScheme.onSurfaceVariant.opacity80,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.drag_indicator,
                    color: context.colorScheme.onSurfaceVariant.opacity80,
                  ),
                  IconButton(
                    onPressed: isDecorator
                        ? null
                        : () {
                            _handleDelete(proxy);
                          },
                    icon: Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
          if (index < totalLength - 1)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: Icon(
                Icons.arrow_downward,
                size: 20,
                color: context.colorScheme.primary.opacity80,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChainHint() {
    final isWarning = _proxies.length == 1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: CommonCard(
        type: CommonCardType.filled,
        radius: 18,
        child: ListTile(
          minTileHeight: 64,
          leading: Icon(
            isWarning ? Icons.warning_amber_rounded : Icons.info_outline,
            color: isWarning
                ? context.colorScheme.error
                : context.colorScheme.primary,
          ),
          title: Text(
            isWarning
                ? appLocalizations.proxyChainMinimumNodesHint
                : appLocalizations.proxyChainInstruction,
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCandidateItem({
    required String proxy,
    required int index,
    required int totalLength,
  }) {
    return CommonInputListItem(
      isFirst: index == 0,
      isLast: index == totalLength - 1,
      onPressed: () {
        _handleAdd(proxy);
      },
      leading: Icon(Icons.account_tree_outlined),
      title: Text(
        proxy,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.bodyMedium?.toJetBrainsMono,
      ),
      trailing: Icon(Icons.add),
    );
  }

  List<ProxyChainCandidateSection> _getVisibleCandidateSections(
    List<String> selectedProxies,
  ) {
    return widget.candidateSections
        .map((section) {
          final proxies = section.proxies.where((item) {
            return !selectedProxies.contains(item);
          }).toList();
          return ProxyChainCandidateSection(
            label: section.label,
            iconData: section.iconData,
            proxies: proxies,
          );
        })
        .where((section) => section.proxies.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final selectedProxies = normalizeProxyChainProxies(_proxies);
    final candidateSections = _getVisibleCandidateSections(selectedProxies);
    return CommonScaffold(
      title: appLocalizations.proxyChains,
      actions: [
        CommonMinIconButtonTheme(
          child: IconButton.filledTonal(
            onPressed: _handleSubmit,
            icon: Icon(Icons.check),
          ),
        ),
        SizedBox(width: 8),
      ],
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                children: [
                  CommonCard(
                    padding: EdgeInsets.zero,
                    type: CommonCardType.filled,
                    radius: 18,
                    child: ListTile(
                      minTileHeight: 64,
                      leading: Icon(
                        Icons.warning_amber_rounded,
                        color: context.colorScheme.error,
                      ),
                      title: Text(appLocalizations.proxyChainWarning),
                    ),
                  ),
                  SizedBox(height: 12),
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: appLocalizations.name,
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
            ),
          ),
          SliverToBoxAdapter(
            child: InfoHeader(
              info: Info(label: appLocalizations.proxyChainConfig),
              actions: [
                if (_proxies.isNotEmpty)
                  CommonMinIconButtonTheme(
                    child: IconButton.filledTonal(
                      tooltip: appLocalizations.clearProxyChain,
                      onPressed: _handleClear,
                      icon: Icon(Icons.delete_outline),
                    ),
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(child: _buildChainHint()),
          SliverToBoxAdapter(child: SizedBox(height: 8)),
          if (_proxies.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: CommonCard(
                  type: CommonCardType.filled,
                  radius: 18,
                  child: ListTile(
                    minTileHeight: 64,
                    title: Text(
                      appLocalizations.nullTip(appLocalizations.proxies),
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.colorScheme.onSurfaceVariant.opacity80,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverReorderableList(
                itemCount: _proxies.length,
                itemBuilder: (context, index) {
                  return _buildProxyItem(
                    proxy: _proxies[index],
                    index: index,
                    totalLength: _proxies.length,
                  );
                },
                proxyDecorator: (child, index, animation) {
                  return commonProxyDecorator(
                    _buildProxyItem(
                      proxy: _proxies[index],
                      index: index,
                      totalLength: _proxies.length,
                      isDecorator: true,
                    ),
                    index,
                    animation,
                  );
                },
                onReorder: _handleReorder,
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _proxyController,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  helperText: appLocalizations.proxyChainInstruction,
                  labelText:
                      '${appLocalizations.proxies}/${appLocalizations.providers}',
                  suffixIcon: IconButton(
                    onPressed: () {
                      _handleAdd(_proxyController.text);
                    },
                    icon: Icon(Icons.add),
                  ),
                ),
                onSubmitted: _handleAdd,
              ),
            ),
          ),
          if (candidateSections.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: CommonCard(
                  type: CommonCardType.filled,
                  radius: 18,
                  child: ListTile(
                    minTileHeight: 64,
                    title: Text(
                      appLocalizations.nullTip(appLocalizations.proxies),
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.colorScheme.onSurfaceVariant.opacity80,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else ...[
            for (final section in candidateSections) ...[
              SliverToBoxAdapter(
                child: InfoHeader(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  info: Info(label: section.label, iconData: section.iconData),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: section.proxies.length,
                  itemBuilder: (context, index) {
                    return _buildCandidateItem(
                      proxy: section.proxies[index],
                      index: index,
                      totalLength: section.proxies.length,
                    );
                  },
                ),
              ),
            ],
          ],
          SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }
}
