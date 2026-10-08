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
import '../../state/status.dart';
import '../../theme/badges.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/two_pane.dart';
import '../../theme/widgets.dart';
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
/// - 手机「标签」布局（设计稿 ANodes）：代理组标签横滑 + 当前组摘要 + 节点网格，左右滑动换组；
/// - 手机「列表」布局：整页一个 CustomScrollView，每个组一张可展开的组卡，展开后接懒加载的 SliverGrid；
/// - 宽屏两栏（设计稿 WNodes）：左栏代理组、右栏当前组的摘要 + 节点网格。
/// 节点网格都是懒加载的 SliverGrid，300 个节点也只构建可见的格子。
class ProxiesPage extends ConsumerStatefulWidget {
  const ProxiesPage({super.key});

  @override
  ConsumerState<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends ConsumerState<ProxiesPage> {
  bool _testingAll = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(meowTabProvider, (prev, next) {
      if (next == MeowTab.proxies) _refreshExtras();
    }, fireImmediately: true);
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
  List<Widget> _groupSlivers(Group g, {required bool expanded, required int columns, required EdgeInsets pad}) {
    final side = EdgeInsets.only(left: pad.left, right: pad.right);
    return [
      SliverPadding(
        padding: side.copyWith(bottom: 8),
        sliver: SliverToBoxAdapter(
          child: GroupCard(
            group: g,
            expanded: expanded,
            onTap: () {
              final set = {...ref.read(expandedGroupsProvider)};
              if (!set.remove(g.name)) set.add(g.name);
              ref.read(expandedGroupsProvider.notifier).state = set;
            },
          ),
        ),
      ),
      if (expanded) ...[
        if (g.type.isComputedSelected)
          SliverPadding(
            padding: side.copyWith(bottom: 8),
            sliver: SliverToBoxAdapter(child: AutoSelectToggle(group: g)),
          ),
        SliverPadding(
          padding: side.copyWith(bottom: 16),
          sliver: NodeSliverGrid(group: g, columns: columns),
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
    final hasProfile = ref.watch(currentProfileProvider) != null;
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
          PopupMenuButton<Object>(
            tooltip: S.nodeView,
            onSelected: (v) => ref
                .read(meowSettingProvider.notifier)
                .updateState(
                  (s) => switch (v) {
                    ProxyLayout l => s.copyWith(proxyLayout: l),
                    NodeCardSize c => s.copyWith(nodeCardSize: c),
                    _ => s,
                  },
                ),
            itemBuilder: (_) => [
              // 两栏时布局是定的，布局切换只给单列（手机、平板竖屏）
              if (!twoPane) ...[
                _menuCaption(S.layout, mm),
                for (final v in ProxyLayout.values)
                  CheckedPopupMenuItem<Object>(
                    value: v,
                    checked: v == layout,
                    child: Text(v.label),
                  ),
                const PopupMenuDivider(),
                _menuCaption(S.cardSize, mm),
              ],
              for (final v in NodeCardSize.values)
                CheckedPopupMenuItem<Object>(
                  value: v,
                  checked: v == size,
                  child: Text(v.label),
                ),
            ],
            child: const RoundGlassButton(icon: Icons.grid_view_rounded, onTap: null),
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
                      pad: EdgeInsets.only(bottom: pad.bottom),
                      wide: true,
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: side.copyWith(top: pad.top, bottom: 12),
            child: title,
          ),
          Expanded(
            child: _GroupTabs(groups: groups, size: size, pad: pad),
          ),
        ],
      );
    }

    final expanded = ref.watch(expandedGroupsProvider);
    return LayoutBuilder(
      builder: (context, c) {
        final columns = nodeColumns(c.maxWidth - pad.horizontal, size);
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: side.copyWith(top: pad.top, bottom: 12),
              sliver: SliverToBoxAdapter(child: title),
            ),
            for (final g in groups)
              ..._groupSlivers(g, expanded: expanded.contains(g.name), columns: columns, pad: pad),
            SliverPadding(padding: EdgeInsets.only(bottom: pad.bottom)),
          ],
        );
      },
    );
  }
}

PopupMenuItem<Object> _menuCaption(String text, MeowTokens mm) => PopupMenuItem(
  enabled: false,
  height: 28,
  child: Text(
    text,
    style: TextStyle(fontSize: MeowFont.caption, color: mm.t2),
  ),
);

/// 一个组的内容：摘要卡 + 懒加载节点网格。标签布局的每一页、宽屏右栏都是它；滚动位置按组记。
class _GroupPage extends StatelessWidget {
  const _GroupPage({required this.group, required this.size, required this.pad, this.wide = false});
  final Group group;
  final NodeCardSize size;

  /// 左右留白 + 底部留白（手机含悬浮底栏的高度）；顶部不用。
  final EdgeInsets pad;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => CustomScrollView(
        key: PageStorageKey('group-${group.name}'),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(left: pad.left, right: pad.right),
            sliver: SliverToBoxAdapter(child: GroupSummary(group: group, wide: wide)),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad.left, wide ? 10 : 12, pad.right, pad.bottom),
            sliver: NodeSliverGrid(
              group: group,
              columns: nodeColumns(c.maxWidth - pad.horizontal, size),
              dense: wide,
            ),
          ),
        ],
      ),
    );
  }
}

/// 标签布局（手机）：顶部一条横向滚动的组标签，下面是 PageView——一页一个组，左右滑动换组。
/// 一次只构建当前页（及滑动中的相邻页）的可见格子。停在哪个组按订阅记在 `Profile.currentGroupName`。
class _GroupTabs extends ConsumerStatefulWidget {
  const _GroupTabs({required this.groups, required this.size, required this.pad});
  final List<Group> groups;
  final NodeCardSize size;
  final EdgeInsets pad;

  @override
  ConsumerState<_GroupTabs> createState() => _GroupTabsState();
}

class _GroupTabsState extends ConsumerState<_GroupTabs> {
  late final PageController _pages = PageController(initialPage: _index);
  final _chipKeys = <String, GlobalKey>{};

  /// 点标签触发的翻页动画期间，途经页的 onPageChanged 不算数。
  bool _programmatic = false;

  int get _index {
    final name = ref.read(
      currentProfileProvider.select((p) => p?.currentGroupName),
    );
    final i = widget.groups.indexWhere((g) => g.name == name);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealChip(_index));
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _revealChip(int i) {
    if (!mounted || i >= widget.groups.length) return;
    final ctx = _chipKeys[widget.groups[i].name]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _setCurrent(int i) {
    globalState.appController.updateCurrentGroupName(widget.groups[i].name);
    _revealChip(i);
  }

  Future<void> _tapChip(int i) async {
    final from = _pages.page?.round() ?? 0;
    if (from == i) return;
    _setCurrent(i);
    if ((from - i).abs() > 1) {
      _pages.jumpToPage(i); // 隔得远就直接跳，不让中间几十页一闪而过
      return;
    }
    _programmatic = true;
    await _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
    _programmatic = false;
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    final pad = widget.pad;
    final current = ref.watch(
      currentProfileProvider.select((p) => p?.currentGroupName),
    );
    var index = groups.indexWhere((g) => g.name == current);
    if (index < 0) index = 0;
    // 换订阅 / 组列表变了：页码对不上就跳过去
    if (!_programmatic) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pages.hasClients || _programmatic) return;
        if (_pages.page?.round() != index) _pages.jumpToPage(index);
      });
    }

    return Column(
      children: [
        SizedBox(
          width: double.infinity,   // 标签少时也靠左，不被 Column 居中
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.only(left: pad.left, right: pad.right),
            child: Row(
              children: [
                for (final (i, g) in groups.indexed)
                  Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 8),
                    child: GroupChip(
                      key: _chipKeys.putIfAbsent(g.name, GlobalKey.new),
                      group: g,
                      selected: i == index,
                      onTap: () => _tapChip(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: PageView.builder(
            controller: _pages,
            itemCount: groups.length,
            onPageChanged: (i) {
              if (!_programmatic) _setCurrent(i);
            },
            itemBuilder: (_, i) => _GroupPage(group: groups[i], size: widget.size, pad: pad),
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
