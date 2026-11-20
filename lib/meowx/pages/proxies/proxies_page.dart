import 'package:bett_box/common/delay_test.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../panel/account.dart';
import '../../state/log_source.dart';
import '../../state/meow_settings.dart';
import '../../state/proxy_providers.dart';
import '../../state/status.dart';
import '../../theme/badges.dart';
import '../../theme/haptics.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/meow_dialog.dart';
import '../../theme/motion.dart';
import '../../theme/page_title.dart';
import '../../theme/sliver_reveal.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import '../../theme/widgets.dart';
import 'group_reveal.dart';
import 'group_widgets.dart';
import 'node_grid.dart';

/// 展开的组（手机列表布局；默认全部收起，不落盘）。
final expandedGroupsProvider = StateProvider<Set<String>>((ref) => {});

/// 宽屏左栏选中的组（没选过 = 第一个组）。
final selectedGroupProvider = StateProvider<String?>((ref) => null);

/// 全部叶子节点（去重）。侧栏「节点」角标也用它，和本页标题的节点数同一口径。
List<Proxy> allLeafProxies(List<Group> groups) {
  final seen = <String>{};
  final out = <Proxy>[];
  for (final g in groups) {
    for (final p in g.all) {
      if (isGroupType(p.type)) continue;
      if (seen.add(p.name)) out.add(p);
    }
  }
  return out;
}

/// 节点页。三种形态：
/// - 手机「单组」布局（同 iOS）：组按钮（点开选组面板）+ 当前组摘要 + 节点网格；
/// - 手机「列表」布局：整页一个 CustomScrollView，每个组一张可展开的组卡，展开后接懒加载的 SliverGrid；
/// - 宽屏两栏（设计稿 WNodes）：左栏代理组、右栏当前组的摘要 + 节点网格。
/// 节点网格都是懒加载的 SliverGrid，300 个节点也只构建可见的格子。
class ProxiesPage extends ConsumerStatefulWidget {
  const ProxiesPage({super.key});

  @override
  ConsumerState<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends ConsumerState<ProxiesPage> with TickerProviderStateMixin {

  /// 正在展开 / 收起的组（列表布局）。收起中的组还在 [expandedGroupsProvider] 之外画着，播完才拆掉。
  final _reveals = <String, GroupReveal>{};

  /// 「全部测速」进行中（标题栏的闪电钮转圈）。
  bool _testingAll = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(meowTabProvider, (prev, next) {
      if (next == MeowTab.proxies) _refreshExtras();
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    for (final r in _reveals.values) {
      r.dispose();
    }
    super.dispose();
  }

  /// 点组卡：展开 / 收起，并只在这一下播动画（滚动回来、重建都不重播）。
  void _toggleGroup(Group g) {
    MeowHaptics.tap();
    final set = {...ref.read(expandedGroupsProvider)};
    final opening = !set.remove(g.name);
    if (opening) set.add(g.name);
    ref.read(expandedGroupsProvider.notifier).state = set;
    if (MeowMotion.reduced(context)) {
      _drop(g.name);
      return;
    }
    final r = _reveals.putIfAbsent(g.name, () => GroupReveal(vsync: this, count: g.all.length, from: opening ? 0 : 1))
      ..count = g.all.length;
    void done() => _drop(g.name);
    opening ? r.open(done) : r.close(done);
    setState(() {});
  }

  /// 动画播完（或不播）：回到静止形态。控制器等这一帧画完再释放——这一帧里还有监听它们的部件。
  void _drop(String name) {
    final r = _reveals.remove(name);
    if (r == null) return;
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => r.dispose());
  }

  void _refreshExtras() {
    if (demoExtras) {
      seedDemoExtras(
        ref,
        allLeafProxies(
          ref.read(currentGroupsStateProvider).value,
        ).map((p) => p.name).toList(),
      );
      return;
    }
    if (ref.read(isLoggedInProvider)) {
      ref.read(accountActionsProvider).refreshExtras(ifStale: true);
    }
  }

  /// 列表布局里的一个组 = 组卡（点按展开 / 收起）+ 展开时的节点（清单或网格），各是独立的 sliver、直接铺在页面底上。
  /// 不用 SliverMainAxisGroup：它滚动后的命中测试有偏移，节点点不中。
  /// 每个 sliver 按组名带 key：展开 / 收起一个组会在中间插入 / 抽走 sliver，没有 key 的话后面的 sliver 逐个错位重配——
  /// 组卡被换成另一个组的内容，下方已展开的网格被拆掉重建。
  /// 展开 / 收起时，组卡下面的节点由 [SliverReveal] 按 [GroupReveal.height] 露出，
  /// 里面的格子按序号错峰（[StaggeredItem]）。静止时同样套着这两层（比例 1、不透明），结构不变、动画结束不重建网格。
  List<Widget> _groupSlivers(
    Group g, {
    required bool expanded,
    required NodeCardSize size,
    required EdgeInsets pad,
  }) {
    final side = EdgeInsets.only(left: pad.left, right: pad.right);
    final reveal = _reveals[g.name];
    final shown = expanded || reveal != null;
    Widget revealed(Widget sliver) => AnimatedBuilder(
      animation: reveal?.height ?? kAlwaysCompleteAnimation,
      builder: (_, child) => SliverReveal(factor: reveal?.height.value ?? 1, sliver: child!),
      child: sliver,
    );
    return [
      SliverPadding(
        key: ValueKey('card:${g.name}'),
        padding: side.copyWith(bottom: 8),
        sliver: SliverToBoxAdapter(
          child: GroupCard(
            group: g,
            expanded: expanded,
            onTap: () => _toggleGroup(g),
          ),
        ),
      ),
      if (shown) ...[
        KeyedSubtree(
          key: ValueKey('grid:${g.name}'),
          child: revealed(
            SliverPadding(
              padding: side.copyWith(bottom: 16),
              sliver: NodeSliverGrid(group: g, size: size, reveal: reveal),
            ),
          ),
        ),
      ],
    ];
  }

  /// 「全部测速」：订阅里全部叶子节点测一遍（同 iOS 标题栏的闪电钮；2026-11-18 用户要求加回来）。
  Future<void> _testAll(List<Group> groups) async {
    if (_testingAll) return;
    MeowHaptics.tap();
    setState(() => _testingAll = true);
    final leaves = allLeafProxies(groups);
    meowLog('全部测速：${leaves.length} 个节点');
    try {
      await delayTest(leaves);
    } finally {
      if (mounted) setState(() => _testingAll = false);
    }
  }

  /// 「节点视图」气泡（照 iOS 的节点视图菜单）：布局（两栏时布局是定的，不给）+ 节点格尺寸，点了即时生效、气泡不收；
  /// 订阅里有远程节点集（proxy-provider）时多一行「更新节点集」。
  void _showViewOptions(BuildContext anchor, bool twoPane) {
    showMeowPopover<void>(
      anchor,
      title: S.nodeView,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final meow = ref.watch(meowSettingProvider);
          final providers = ref.watch(remoteProxyProvidersProvider);
          final updating = ref.watch(updatingProxyProvidersProvider);
          void update(MeowSettings Function(MeowSettings) f) => ref.read(meowSettingProvider.notifier).updateState(f);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!twoPane) ...[
                const MeowDialogLabel(S.layout),
                MeowSlideSegment<ProxyLayout>(
                  items: [for (final v in ProxyLayout.values) (v, v.label)],
                  selected: meow.proxyLayout,
                  onChanged: (v) => update((s) => s.copyWith(proxyLayout: v)),
                ),
              ],
              const MeowDialogLabel(S.cardSize),
              MeowSlideSegment<NodeCardSize>(
                items: [for (final v in NodeCardSize.values) (v, v.label)],
                selected: meow.nodeCardSize,
                onChanged: (v) => update((s) => s.copyWith(nodeCardSize: v)),
              ),
              if (providers.isNotEmpty) ...[
                const SizedBox(height: 14),
                M3ListRow(
                  title: updating ? '正在更新节点集…' : '更新节点集',
                  subtitle: '重新拉取订阅里的 ${providers.length} 个远程节点集',
                  leading: updating
                      ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync_rounded),
                  onTap: updating
                      ? null
                      : () async {
                          MeowHaptics.tap();
                          final failed = await updateProxyProviders(ref);
                          globalState.showNotifier(failed.isEmpty ? '节点集已更新' : '更新失败：${failed.join('；')}');
                        },
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final twoPane = ref.watch(isTwoPaneProvider);
    final groups = ref.watch(currentGroupsStateProvider.select((s) => s.value));
    // 只关心有没有订阅：订阅整个 Profile 的话，点一次节点（selectedMap）、换一次组（currentGroupName）整页都要重建
    final hasProfile = ref.watch(currentProfileProvider.select((p) => p != null));
    final size = ref.watch(meowSettingProvider.select((s) => s.nodeCardSize));
    final layout = ref.watch(meowSettingProvider.select((s) => s.proxyLayout));
    // 有侧栏（宽屏、平板竖屏）用壳约定的留白；手机左右 16，底部让出悬浮底栏（它盖在内容上）
    final pad = ref.watch(isWideLayoutProvider)
        ? widePagePadding()
        : EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.paddingOf(context).bottom);
    final side = EdgeInsets.only(left: pad.left, right: pad.right);
    final listPad = pad;

    final title = PageTitle(
      MeowTab.proxies.label,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (anchor) => RoundGlassButton(
              icon: switch (size) {
                NodeCardSize.compact => Icons.apps_rounded,
                NodeCardSize.standard => Icons.grid_view_rounded,
                NodeCardSize.large => Icons.view_agenda_rounded,
              },
              tooltip: S.nodeView,
              onTap: () => _showViewOptions(anchor, twoPane),
            ),
          ),
          const SizedBox(width: 8),
          RoundGlassButton(
            icon: Icons.bolt_rounded,
            filled: true,
            busy: _testingAll,
            tooltip: S.testAll,
            onTap: groups.isEmpty ? null : () => _testAll(groups),
          ),
        ],
      ),
      subtitle: Text(
        S.groupsAndNodes(groups.length, allLeafProxies(groups).length),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: MeowFont.footnote, color: context.cs.onSurfaceVariant),
      ),
    );
    if (!hasProfile || groups.isEmpty) {
      return ListView(
        padding: pad,
        children: [
          title,
          const SizedBox(height: 80),
          _EmptyState(
            title: hasProfile ? '暂无代理组' : S.noConfig,
            subtitle: hasProfile ? '当前订阅没有代理组，或核心尚未加载' : '去「我的」页导入订阅',
            onTap: hasProfile ? null : () => goTab(ref, MeowTab.me),
          ),
        ],
      );
    }

    if (twoPane) {
      final selectedName = ref.watch(selectedGroupProvider);
      final selected = groups.firstWhereOrNull((g) => g.name == selectedName) ?? groups.first;
      return Padding(
        padding: pad.copyWith(bottom: 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 250,
                    child: ListView.separated(
                      padding: EdgeInsets.only(bottom: pad.bottom),
                      itemCount: groups.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 3),
                      itemBuilder: (_, i) => M3SegmentSlot(
                        index: i,
                        count: groups.length,
                        child: GroupCard(
                          group: groups[i],
                          selected: groups[i].name == selected.name,
                          onTap: () {
                            if (groups[i].name != selected.name) MeowHaptics.select();
                            ref.read(selectedGroupProvider.notifier).state = groups[i].name;
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _GroupPage(
                      group: selected,
                      size: size,
                      bottom: listPad.bottom,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (layout == ProxyLayout.tabs) {
      return _SingleGroup(groups: groups, size: size, pad: listPad, title: title);
    }

    final expanded = ref.watch(expandedGroupsProvider);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: side.copyWith(top: pad.top, bottom: 12),
          sliver: SliverToBoxAdapter(child: title),
        ),
        for (final g in groups)
          ..._groupSlivers(g, expanded: expanded.contains(g.name), size: size, pad: pad),
        SliverPadding(padding: EdgeInsets.only(bottom: listPad.bottom)),
      ],
    );
  }
}

/// 宽屏右栏：当前组的摘要卡 + 懒加载节点网格（WNodes 的小一号格子）；滚动位置按组记。
class _GroupPage extends StatelessWidget {
  const _GroupPage({required this.group, required this.size, required this.bottom});
  final Group group;
  final NodeCardSize size;

  /// 底部留白。
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: PageStorageKey('group-${group.name}'),
      slivers: [
        SliverToBoxAdapter(child: GroupSummary(group: group, wide: true)),
        SliverPadding(
          padding: EdgeInsets.only(top: 10, bottom: bottom),
          sliver: NodeSliverGrid(group: group, size: size, dense: true),
        ),
      ],
    );
  }
}

/// 记下单组布局停在哪个组：按订阅存在 `Profile.currentGroupName`（重进节点页、重启后还是它）。测试里换成不碰 globalState 的替身。
final rememberGroupProvider = Provider<void Function(String name)>(
  (ref) => (name) => globalState.appController.updateCurrentGroupName(name),
);

/// 组延迟（= 当前选中节点的延迟，同 [GroupSummary]）：单组布局 chip 行尾的测速钮上显示它。
final _groupDelayProvider = Provider.autoDispose.family<int?, Group>((ref, group) {
  final current = ref.watch(getSelectedProxyNameProvider(group.name)) ?? '';
  return current.isEmpty ? null : ref.watch(getDelayProvider(proxyName: current, testUrl: group.testUrl));
});

/// 单组布局（手机 / 平板竖屏，画布稿 Nodes）：标题、代理组 chip（行尾测速本组）与节点（清单或网格，懒加载）在同一个滚动视图里。
/// 换组：新的一组淡入、旧的当帧撤走（摘要和节点按组名带 key，不让两份大清单同时活着做交叉淡化），并回到顶部。
class _SingleGroup extends ConsumerStatefulWidget {
  const _SingleGroup({
    required this.groups,
    required this.size,
    required this.pad,
    required this.title,
  });
  final List<Group> groups;
  final NodeCardSize size;
  final EdgeInsets pad;
  final Widget title;

  @override
  ConsumerState<_SingleGroup> createState() => _SingleGroupState();
}

class _SingleGroupState extends ConsumerState<_SingleGroup> with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();

  /// 换组时新内容的淡入；静止时停在 1（不透明，不开图层）。
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1);
  late final _opacity = CurvedAnimation(parent: _fade, curve: Curves.easeOut);

  @override
  void dispose() {
    _opacity.dispose();
    _fade.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _pick(String name) {
    ref.read(rememberGroupProvider)(name);
    if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);   // 换了组从头看
    if (!MeowMotion.reduced(context)) _fade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    final pad = widget.pad;
    final side = EdgeInsets.only(left: pad.left, right: pad.right);
    // 没记过、或记下的组已不在当前订阅里 → 第一个组
    final name = ref.watch(currentProfileProvider.select((p) => p?.currentGroupName));
    final group = groups.firstWhereOrNull((g) => g.name == name) ?? groups.first;
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: side.copyWith(top: pad.top, bottom: 14),
          sliver: SliverToBoxAdapter(child: widget.title),
        ),
        // 代理组 chip + 行尾「测速本组」（带组延迟）；组摘要卡去掉了（2026-11-17，同 iOS）：策略写在组卡 / chip 上，
        // 当前节点在下面的清单里是选中的那一行
        SliverPadding(
          padding: EdgeInsets.only(bottom: 14, right: pad.right),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: GroupChipBar(
                    groups: groups,
                    selected: group.name,
                    onSelected: _pick,
                    padding: EdgeInsets.only(left: pad.left, right: 8),
                  ),
                ),
                GroupTestButton(
                  key: ValueKey('test:${group.name}'),
                  group: group,
                  delay: ref.watch(_groupDelayProvider(group)),
                  compact: true,
                  height: 40,
                ),
              ],
            ),
          ),
        ),
        SliverFadeTransition(
          key: ValueKey('grid:${group.name}'),
          opacity: _opacity,
          sliver: SliverPadding(
            padding: EdgeInsets.fromLTRB(pad.left, 0, pad.right, pad.bottom),
            sliver: NodeSliverGrid(group: group, size: widget.size),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.subtitle, this.onTap});
  final String title, subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MeowIcon(MeowGlyph.nodes, size: 46, color: mm.t2),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: MeowFont.headline,
                  fontWeight: FontWeight.w600,
                  color: mm.t1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: MeowFont.subheadline,
                  color: mm.t2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
