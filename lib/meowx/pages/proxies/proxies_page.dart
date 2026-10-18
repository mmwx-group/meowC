import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/proxies/common.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../panel/account.dart';
import '../../state/meow_settings.dart';
import '../../state/node_sort.dart';
import '../../state/status.dart';
import '../../theme/badges.dart';
import '../../theme/morph_menu.dart';
import '../../theme/motion.dart';
import '../../theme/page_title.dart';
import '../../theme/sliver_reveal.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import '../../theme/widgets.dart';
import 'group_reveal.dart';
import 'group_widgets.dart';
import 'node_grid.dart';
import 'node_parts.dart';

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
  bool _testingAll = false;

  /// 正在展开 / 收起的组（列表布局）。收起中的组还在 [expandedGroupsProvider] 之外画着，播完才拆掉。
  final _reveals = <String, GroupReveal>{};

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

  /// 列表布局里的一个组 = 组卡（点按展开 / 收起）+ 展开时的「自动选择」行与节点网格，各是独立的 sliver、直接铺在页面底上。
  /// 不用 SliverMainAxisGroup：它滚动后的命中测试有偏移，节点点不中。
  /// 每个 sliver 按组名带 key：展开 / 收起一个组会在中间插入 / 抽走 sliver，没有 key 的话后面的 sliver 逐个错位重配——
  /// 组卡被换成另一个组的内容，下方已展开的网格被拆掉重建。
  /// 展开 / 收起时，组卡下面那段（「自动选择」行 + 网格）由 [SliverReveal] 按 [GroupReveal.height] 露出，
  /// 里面的格子按序号错峰（[StaggeredItem]）。静止时同样套着这两层（比例 1、不透明），结构不变、动画结束不重建网格。
  List<Widget> _groupSlivers(Group g, {required bool expanded, required NodeCardSize size, required EdgeInsets pad}) {
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
        if (g.type.isComputedSelected)
          KeyedSubtree(
            key: ValueKey('auto:${g.name}'),
            child: revealed(
              SliverPadding(
                padding: side.copyWith(bottom: 8),
                sliver: SliverToBoxAdapter(
                  child: StaggeredItem(reveal: reveal, index: 0, child: AutoSelectToggle(group: g)),
                ),
              ),
            ),
          ),
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

  Future<void> _testAll(List<Group> groups) async {
    if (_testingAll) return;
    setState(() => _testingAll = true);
    try {
      await delayTest(allLeafProxies(groups));
    } finally {
      if (mounted) setState(() => _testingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
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
    final testAll = groups.isEmpty ? null : () => _testAll(groups);

    final title = PageTitle(
      MeowTab.proxies.label,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MeowMenuButton<Object>(
            width: 200,
            alignEnd: true,
            fromColor: mm.elev,
            onSelected: (v) {
              // 排序存在 Bettbox 的 proxiesStyle 里（托盘节点菜单同一份），其余是 MeowX 自己的设置
              if (v is ProxiesSortType) {
                ref.read(proxiesStyleSettingProvider.notifier).updateState((s) => s.copyWith(sortType: v));
                return;
              }
              ref
                  .read(meowSettingProvider.notifier)
                  .updateState(
                    (s) => switch (v) {
                      ProxyLayout l => s.copyWith(proxyLayout: l),
                      NodeCardSize c => s.copyWith(nodeCardSize: c),
                      _ => s,
                    },
                  );
            },
            entries: () {
              // 本页不按排序重建（网格自己盯着），打开菜单时现读
              final sort = ref.read(proxiesStyleSettingProvider).sortType;
              return [
                // 两栏时布局是定的，布局切换只给单列（手机、平板竖屏）
                if (!twoPane) ...[
                  const MeowMenuCaption(S.layout),
                  for (final v in ProxyLayout.values) MeowMenuItem<Object>(v, v.label, checked: v == layout),
                  const MeowMenuDivider(),
                ],
                const MeowMenuCaption(S.cardSize),
                for (final v in NodeCardSize.values) MeowMenuItem<Object>(v, v.label, checked: v == size),
                const MeowMenuDivider(),
                const MeowMenuCaption(S.sort),
                for (final v in ProxiesSortType.values) MeowMenuItem<Object>(v, v.label, checked: v == sort),
              ];
            },
            builder: (_, open) => RoundGlassButton(icon: Icons.grid_view_rounded, tooltip: S.nodeView, onTap: open),
          ),
          const SizedBox(width: 8),
          if (twoPane)
            PillButton(label: S.testAll, filled: true, busy: _testingAll, onTap: testAll)
          else
            RoundGlassButton(
              icon: Icons.bolt_rounded,
              filled: true,
              busy: _testingAll,
              tooltip: S.testAll,
              onTap: testAll,
            ),
        ],
      ),
      subtitle: Text(
        S.groupsAndNodes(groups.length, allLeafProxies(groups).length),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
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
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, i) => GroupCard(
                        group: groups[i],
                        selected: groups[i].name == selected.name,
                        onTap: () => ref.read(selectedGroupProvider.notifier).state = groups[i].name,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _GroupPage(
                      group: selected,
                      size: size,
                      bottom: pad.bottom,
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
      return _SingleGroup(groups: groups, size: size, pad: pad, title: title);
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
        SliverPadding(padding: EdgeInsets.only(bottom: pad.bottom)),
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

/// 单组布局（手机 / 平板竖屏，对齐 iOS）：标题、组按钮、当前组的摘要与懒加载节点网格在同一个滚动视图里。
/// 点组按钮弹出选组面板换组——以前是一排横向滚动的组标签 + PageView 左右滑动换组，组一多要来回划着找。
/// 换组：新的一组淡入、旧的当帧撤走（摘要和网格按组名带 key，不让两份大网格同时活着做交叉淡化），并回到顶部。
class _SingleGroup extends ConsumerStatefulWidget {
  const _SingleGroup({required this.groups, required this.size, required this.pad, required this.title});
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

  Future<void> _pick(BuildContext anchor, Group current) async {
    final name = await showGroupPicker(
      anchor,
      groups: widget.groups,
      current: current.name,
      wide: ref.read(isWideLayoutProvider),
    );
    if (!mounted || name == null || name == current.name) return;
    ref.read(rememberGroupProvider)(name);
    if (_scroll.hasClients) _scroll.jumpTo(0);   // 换了组从头看
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
          padding: side.copyWith(top: pad.top, bottom: 12),
          sliver: SliverToBoxAdapter(child: widget.title),
        ),
        SliverPadding(
          padding: side.copyWith(bottom: 12),
          sliver: SliverToBoxAdapter(
            child: GroupPickerButton(
              group: group,
              groupCount: groups.length,
              onTap: (anchor) => _pick(anchor, group),
            ),
          ),
        ),
        SliverFadeTransition(
          key: ValueKey('summary:${group.name}'),
          opacity: _opacity,
          sliver: SliverPadding(
            padding: side,
            sliver: SliverToBoxAdapter(child: GroupSummary(group: group)),
          ),
        ),
        SliverFadeTransition(
          key: ValueKey('grid:${group.name}'),
          opacity: _opacity,
          sliver: SliverPadding(
            padding: EdgeInsets.fromLTRB(pad.left, 12, pad.right, pad.bottom),
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
