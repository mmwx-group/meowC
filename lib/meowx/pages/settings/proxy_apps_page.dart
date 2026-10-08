import 'dart:async';
import 'dart:typed_data';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../me/me_kit.dart';

/// 代理应用（Android 分应用代理）：支持仅代理勾选应用的白名单，以及勾选应用直连的黑名单。
/// 两份名单沿用 Bettbox 的 `VpnProps.accessControl`，切换模式或开关时保留各自的选择。
/// 运行中改动由 Bettbox 的 VpnManager 弹「重启生效」提示。排序、手动包名等选项在「高级 → 访问控制」。
class ProxyAppsPage extends ConsumerStatefulWidget {
  const ProxyAppsPage({super.key});

  @override
  ConsumerState<ProxyAppsPage> createState() => _ProxyAppsPageState();
}

class _ProxyAppsPageState extends ConsumerState<ProxyAppsPage> with WidgetsBindingObserver {
  final _search = TextEditingController();
  bool _loading = false;
  bool _denied = false;
  bool _showSystem = false;

  /// 进页面时已勾选的应用：排在最前。勾选过程中不重排，免得刚点的那一行跳走。
  late Set<String> _pinned = ref.read(vpnSettingProvider).accessControl.currentList.toSet();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (ref.read(vpnSettingProvider).accessControl.enable) unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置授权「读取应用列表」回来后重试
    if (state == AppLifecycleState.resumed && _denied) unawaited(_load(force: true));
  }

  Future<void> _load({bool force = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final list = await globalState.appController.getPackages(forceRefresh: force);
      if (mounted) {
        setState(() {
          _denied = list.isEmpty;
          _pinned = ref.read(vpnSettingProvider).accessControl.currentList.toSet();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setEnabled(bool on) {
    ref.read(vpnSettingProvider.notifier).updateState(
      (s) => s.copyWith.accessControl(enable: on),
    );
    if (on) unawaited(_load());
  }

  void _setMode(AccessControlMode mode) {
    ref.read(vpnSettingProvider.notifier).updateState(
      (s) => s.copyWith.accessControl(mode: mode),
    );
    setState(() {
      _pinned = ref.read(vpnSettingProvider).accessControl.currentList.toSet();
    });
  }

  void _toggle(String packageName, bool on) {
    ref.read(vpnSettingProvider.notifier).updateState((s) {
      final list = [...s.accessControl.currentList];
      if (on) {
        if (!list.contains(packageName)) list.add(packageName);
      } else {
        list.remove(packageName);
      }
      return switch (s.accessControl.mode) {
        AccessControlMode.acceptSelected => s.copyWith.accessControl(acceptList: list),
        AccessControlMode.rejectSelected => s.copyWith.accessControl(rejectList: list),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final access = ref.watch(vpnSettingProvider.select((s) => s.accessControl));
    final packages = ref.watch(packagesProvider);
    final selected = access.currentList.toSet();
    final isWhitelist = access.mode == AccessControlMode.acceptSelected;
    final q = _search.text.trim().toLowerCase();

    // 没有联网权限的应用代理不代理都一样，不列；系统应用默认收起（已勾选的始终显示）
    final visible = packages.where((p) {
      final chosen = selected.contains(p.packageName);
      if (!p.internet && !chosen) return false;
      if (!_showSystem && p.system && !chosen) return false;
      if (q.isEmpty) return true;
      return p.label.toLowerCase().contains(q) || p.packageName.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) {
        final sa = _pinned.contains(a.packageName), sb = _pinned.contains(b.packageName);
        if (sa != sb) return sa ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

    final small = TextStyle(fontSize: MeowFont.caption, color: mm.t2);
    // 总开关 + 模式（樱粉主卡）
    final hero = Container(
      decoration: BoxDecoration(color: mm.hero, borderRadius: BorderRadius.circular(24)),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setEnabled(!access.enable),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '启用应用分流',
                        style: TextStyle(fontSize: MeowFont.callout, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        !access.enable
                            ? '关闭时全部应用都走代理'
                            : '${isWhitelist ? '白名单：只有选中的应用走代理' : '黑名单：选中的应用不走代理'}。修改后重新连接生效',
                        style: small,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Switch(value: access.enable, onChanged: _setEnabled),
              ],
            ),
          ),
          if (access.enable) ...[
            const SizedBox(height: 12),
            MeowSegment<AccessControlMode>(
              items: const [(AccessControlMode.acceptSelected, '白名单'), (AccessControlMode.rejectSelected, '黑名单')],
              value: access.mode,
              onChanged: _setMode,
            ),
          ],
        ],
      ),
    );

    final scroll = CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(child: hero),
        ),
        if (!access.enable)
          _fill(
            Text(
              '开启后可选择白名单或黑名单，并勾选对应应用。\n修改模式或名单后需要重新连接才会生效。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2),
            ),
          )
        else ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '搜索应用名 / 包名',
                            prefixIcon: Icon(Icons.search_rounded, size: 20, color: mm.t2),
                            filled: true,
                            fillColor: mm.elev,
                            contentPadding: const EdgeInsets.symmetric(vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      MePill(
                        label: '系统应用',
                        selected: _showSystem,
                        onTap: () => setState(() => _showSystem = !_showSystem),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 两段放不下一行（大字号）时折成两行
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      Text('已选 ${selected.length} 个 · 已选的排在前面', style: small),
                      Text('共 ${packages.where((p) => p.internet).length} 个可联网应用', style: small),
                    ],
                  ),
                ],
              ),
            ),
          ),
          _list(mm, visible, selected),
        ],
      ],
    );

    return MeSubPage(
      title: '代理应用',
      actions: [
        if (access.enable)
          RoundGlassButton(
            icon: Icons.refresh_rounded,
            tooltip: '重新读取应用列表',
            busy: _loading,
            onTap: () => _load(force: true),
          ),
      ],
      body: access.enable ? RefreshIndicator(onRefresh: () => _load(force: true), child: scroll) : scroll,
    );
  }

  /// 占满列表剩余高度的居中提示；可滚：横屏 / 大字号时高度不够，按钮也要能滚到
  Widget _fill(Widget child) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Padding(padding: const EdgeInsets.all(32), child: child),
    ),
  );

  Widget _list(MeowTokens mm, List<Package> visible, Set<String> selected) {
    if (_loading && visible.isEmpty) {
      return _fill(const CircularProgressIndicator());
    }
    if (_denied) {
      return _fill(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.apps_outage_rounded, size: 46, color: mm.t2),
            const SizedBox(height: 12),
            Text('读不到应用列表', style: TextStyle(fontSize: MeowFont.headline, fontWeight: FontWeight.w600, color: mm.t1)),
            const SizedBox(height: 4),
            Text(
              '部分系统需要单独授予「读取应用列表」权限',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => app.requestPackageListPermission(),
              child: const Text('去授权'),
            ),
          ],
        ),
      );
    }
    if (visible.isEmpty) {
      return _fill(
        Text(
          _showSystem ? '没有匹配的应用' : '没有匹配的应用，试试打开右上的「系统应用」',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2),
        ),
      );
    }
    // 一整张白卡装全部应用行：底画在 sliver 上，行仍然按需构建
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(context).bottom),
      sliver: DecoratedSliver(
        decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(24)),
        sliver: SliverPadding(
          padding: const EdgeInsets.all(6),
          sliver: SliverList.separated(
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 2),
            itemBuilder: (_, i) {
              final p = visible[i];
              final on = selected.contains(p.packageName);
              return Material(
                color: on ? mm.soft : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _toggle(p.packageName, !on),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 58),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
                      child: Row(
                        children: [
                          _AppIcon(packageName: p.packageName),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w600, color: mm.t1),
                                ),
                                Text(
                                  p.packageName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: MeowFont.mono(size: MeowFont.caption2, color: mm.t2),
                                ),
                              ],
                            ),
                          ),
                          Checkbox(value: on, onChanged: (v) => _toggle(p.packageName, v ?? false)),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AppIcon extends StatefulWidget {
  const _AppIcon({required this.packageName});
  final String packageName;

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  late Future<Uint8List?> _icon = _fetch();

  Future<Uint8List?> _fetch() => app.getPackageIcon(widget.packageName);

  @override
  void didUpdateWidget(_AppIcon old) {
    super.didUpdateWidget(old);
    if (old.packageName != widget.packageName) _icon = _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final size = 38 * MediaQuery.devicePixelRatioOf(context);
    return SizedBox(
      width: 38,
      height: 38,
      child: FutureBuilder<Uint8List?>(
        future: _icon,
        builder: (_, snap) {
          final data = snap.data;
          if (data == null) return Icon(Icons.android_rounded, size: 26, color: mm.t2);
          return Image.memory(
            data,
            gaplessPlayback: true,
            cacheWidth: size.ceil(),
            cacheHeight: size.ceil(),
            errorBuilder: (_, _, _) => Icon(Icons.android_rounded, size: 26, color: mm.t2),
          );
        },
      ),
    );
  }
}
