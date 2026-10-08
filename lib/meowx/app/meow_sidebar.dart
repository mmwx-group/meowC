import 'dart:async';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pages/proxies/proxies_page.dart' show allLeafProxies;
import '../state/connection.dart';
import '../state/format.dart';
import '../theme/tokens.dart';
import '../theme/widgets.dart';
import 'meow_tab.dart';

/// 侧栏放不放得下完整形态：窗口 / 屏幕宽 ≥ 1000 用 220 宽的完整侧栏，700–999 用 84 宽的图标栏。
const sidebarFullMinWidth = 1000.0;

/// 宽屏左侧栏（Windows 窗口、Android 平板）：品牌 → 四个目的地 → 常驻连接控制。
/// 完整形态 220 宽：导航带名称和计数，底部是连接卡（状态、电源键、当前节点、Windows 上的 TUN / 系统代理）；
/// 紧凑形态 84 宽：只有图标，底部只留电源键。
class MeowSidebar extends ConsumerWidget {
  const MeowSidebar({super.key, required this.selected, required this.onSelect, required this.compact});

  final MeowTab selected;
  final ValueChanged<MeowTab> onSelect;
  final bool compact;

  static const fullWidth = 220.0;
  static const compactWidth = 84.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    // 和节点页标题「N 个节点」同一口径：只数当前模式下可见组里的叶子节点
    final nodeCount = ref.watch(currentGroupsStateProvider.select((s) => allLeafProxies(s.value).length));
    final connCount = ref.watch(connStatsProvider.select((s) => s.total));
    int? badge(MeowTab t) => switch (t) {
      MeowTab.proxies => nodeCount,
      MeowTab.connections => connCount,
      _ => null,
    };

    final nav = [
      for (final t in MeowTab.values)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _NavItem(tab: t, on: t == selected, compact: compact, badge: badge(t), onTap: () => onSelect(t)),
        ),
    ];

    return Container(
      width: compact ? compactWidth - 12 : fullWidth - 12,
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(22)),
      // 矮窗口（手机横屏、缩到最小的窗口）放不下时栏内滚动，保证电源键不画到栏外
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 48,
                    child: Row(
                      mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
                      children: [
                        const BrandHead(size: 36),
                        if (!compact) ...[
                          const SizedBox(width: 8),
                          Text(
                            'MeowX',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              color: mm.t1,
                              fontFamilyFallback: meowRounded,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...nav,
                  const Spacer(),
                  const SizedBox(height: 8),
                  if (compact) const Center(child: _CompactPower()) else _ConnectionCard(onOpenNodes: () => onSelect(MeowTab.proxies)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.tab, required this.on, required this.compact, required this.badge, required this.onTap});
  final MeowTab tab;
  final bool on, compact;
  final int? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final ink = on ? mm.accent : mm.t2;
    Widget body = Material(
      color: on ? mm.soft : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
          child: Row(
            mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              MeowIcon(tab.glyph, size: 20, color: ink),
              if (!compact) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: ink),
                  ),
                ),
                if ((badge ?? 0) > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      badge! > 999 ? '999+' : '$badge',
                      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
                      style: MeowFont.mono(size: 11, weight: FontWeight.w700, color: mm.t2),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    if (compact) body = Tooltip(message: tab.label, child: body);
    return Semantics(selected: on, child: body);
  }
}

class _CompactPower extends ConsumerWidget {
  const _CompactPower();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(connPhaseProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MeowPowerButton(
        size: 48,
        on: phase == ConnPhase.on,
        busy: phase == ConnPhase.connecting,
        enabled: ref.watch(powerEnabledProvider),
        onTap: () => unawaited(ref.read(powerProvider.notifier).toggle()),
      ),
    );
  }
}

/// 侧栏底部的常驻连接控制：任何页面都能开关，并看得到当前节点和接管方式。
class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard({required this.onOpenNodes});
  final VoidCallback onOpenNodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final phase = ref.watch(connPhaseProvider);
    final on = phase == ConnPhase.on;
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final runTime = ref.watch(runTimeProvider);
    final node = ref.watch(currentNodeProvider);
    final (label, dot) = switch (phase) {
      ConnPhase.on => ('已连接', mm.good),
      ConnPhase.connecting => ('连接中', mm.mid),
      ConnPhase.off => ('未连接', mm.t2),
    };
    final sub = on && runTime != null
        ? '${modeLabel(mode)}模式 · ${fmtUptime(Duration(milliseconds: runTime))}'
        : (ref.watch(hasProfileProvider) ? '${modeLabel(mode)}模式 · 已就绪' : '还没有订阅');
    final nodeName = switch (mode) {
      Mode.direct => '直连',
      _ => (node == null || node.leaf.isEmpty)
          ? (node?.group ?? (ref.watch(initProvider) ? '没有代理组' : '正在加载…'))
          : stripFlag(node.leaf),
    };
    final code = mode == Mode.direct || node == null ? null : regionCode(node.leaf);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: on ? mm.hero : mm.card2, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StatusDot(color: dot),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: mm.t1),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: mm.t2)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MeowPowerButton(
                size: 44,
                on: on,
                busy: phase == ConnPhase.connecting,
                enabled: ref.watch(powerEnabledProvider),
                onTap: () => unawaited(ref.read(powerProvider.notifier).toggle()),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Material(
            color: mm.elev,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onOpenNodes,
              child: Container(
                constraints: const BoxConstraints(minHeight: 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    if (code != null) ...[RegionTag(code), const SizedBox(width: 6)],
                    Expanded(
                      child: Text(
                        nodeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mm.t1),
                      ),
                    ),
                    MeowIcon(MeowGlyph.chevron, size: 13, color: mm.t2),
                  ],
                ),
              ),
            ),
          ),
          if (isDesktopUi) ...[
            const SizedBox(height: 8),
            const _TakeoverToggles(),
          ],
        ],
      ),
    );
  }
}

/// TUN / 系统代理：两个可以同时打开的开关钮（不是二选一）。
class _TakeoverToggles extends ConsumerWidget {
  const _TakeoverToggles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final tun = ref.watch(tunEnabledProvider);
    final sys = ref.watch(systemProxyEnabledProvider);
    final (tunHint, tunWarn) = ref.watch(tunHintProvider);
    final installing = ref.watch(takeoverProvider.select((s) => s.installing));
    final port = ref.watch(patchClashConfigProvider.select((s) => s.mixedPort));

    Widget toggle(String label, bool value, String tip, VoidCallback? onTap, {bool warn = false}) => Expanded(
      child: Tooltip(
        message: tip,
        child: Semantics(
          button: true,
          toggled: value,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: value ? mm.t1 : mm.elev,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 32),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (warn) ...[Icon(Icons.error_outline_rounded, size: 13, color: value ? mm.bg : mm.mid), const SizedBox(width: 3)],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: value ? mm.bg : mm.t2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Row(
      children: [
        toggle(
          'TUN',
          tun,
          '虚拟网卡（TUN）：$tunHint',
          installing ? null : () => unawaited(ref.read(takeoverProvider.notifier).setTun(context, !tun)),
          warn: tunWarn,
        ),
        const SizedBox(width: 6),
        toggle(
          '系统代理',
          sys,
          '把系统 HTTP 代理指向 127.0.0.1:$port',
          () => ref.read(takeoverProvider.notifier).setSystemProxy(!sys),
        ),
      ],
    );
  }
}
