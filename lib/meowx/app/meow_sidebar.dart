import 'dart:async';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/connection.dart';
import '../state/format.dart';
import '../state/node_count.dart';
import '../theme/m3.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/widgets.dart';
import 'meow_tab.dart';

/// 侧栏放不放得下完整形态：窗口 / 屏幕宽 ≥ 1000 用 220 宽的完整侧栏，700–999 用 84 宽的图标栏。
const sidebarFullMinWidth = 1000.0;

/// 宽屏左侧栏（Windows / Linux 窗口、Android 平板）：品牌 → 四个目的地 → 常驻连接微控制台。
/// 完整形态 220 宽：柔和通透选中态 + 桌面 hover 反馈 + 计数徽章 + 底部连接控制卡（电源键、当前节点、TUN / 系统代理）；
/// 紧凑形态 84 宽：居中图标栏 + 底部电源键。
class MeowSidebar extends StatelessWidget {
  const MeowSidebar({super.key, required this.selected, required this.onSelect, required this.compact});

  final MeowTab selected;
  final ValueChanged<MeowTab> onSelect;
  final bool compact;

  static const fullWidth = 220.0;
  static const compactWidth = 84.0;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final nav = [
      for (final t in MeowTab.values)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _NavItem(tab: t, on: t == selected, compact: compact, onTap: () => onSelect(t)),
        ),
    ];

    return Container(
      width: compact ? compactWidth - 12 : fullWidth - 12,
      decoration: BoxDecoration(
        color: cs.card,
        borderRadius: BorderRadius.circular(MeowShape.xl),
        border: Border.all(color: cs.cardBorder, width: 0.8),
      ),
      padding: EdgeInsets.all(compact ? 10 : 12),
      // 矮窗口放不下时栏内滚动，保证电源键不画到栏外
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 46,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 4),
                      child: Row(
                        mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
                        children: [
                          const BrandHead(size: 34),
                          if (!compact) ...[
                            const SizedBox(width: 9),
                            Text(
                              'MeowX',
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                                color: cs.onSurface,
                                fontFamilyFallback: meowRounded,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...nav,
                  const Spacer(),
                  const SizedBox(height: 10),
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

class _NavItem extends StatefulWidget {
  const _NavItem({required this.tab, required this.on, required this.compact, required this.onTap});
  final MeowTab tab;
  final bool on, compact;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final dark = context.isDarkMode;
    final on = widget.on;
    final compact = widget.compact;
    final ink = on ? (dark ? Colors.white : cs.primary) : cs.onSurfaceVariant;
    final dur = MeowMotion.of(context, const Duration(milliseconds: 180));
    final radius = BorderRadius.circular(16);

    Widget body = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: dur,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          gradient: on
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: dark
                      ? [Colors.white.withValues(alpha: 0.14), cs.primary.withValues(alpha: 0.20)]
                      : [cs.primary.withValues(alpha: 0.11), cs.primary.withValues(alpha: 0.05)],
                )
              : null,
          color: on
              ? null
              : _hovered
              ? cs.onSurface.withValues(alpha: dark ? 0.06 : 0.04)
              : Colors.transparent,
          borderRadius: radius,
          border: Border.all(
            color: on
                ? (dark ? Colors.white.withValues(alpha: 0.22) : cs.primary.withValues(alpha: 0.24))
                : Colors.transparent,
            width: 0.9,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            splashColor: cs.primary.withValues(alpha: 0.08),
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(minHeight: 46),
              padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
              child: Row(
                mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: [
                  if (!compact) ...[
                    AnimatedContainer(
                      duration: dur,
                      curve: Curves.easeOutCubic,
                      width: 3,
                      height: on ? 16 : 0,
                      margin: const EdgeInsets.only(right: 9),
                      decoration: BoxDecoration(
                        color: on ? cs.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                  MeowIcon(widget.tab.glyph, size: 20, color: ink),
                  if (!compact) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.tab.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: ink),
                      ),
                    ),
                    if (widget.tab == MeowTab.proxies || widget.tab == MeowTab.connections) _NavBadge(widget.tab, active: on),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (compact) body = Tooltip(message: widget.tab.label, child: body);
    return Semantics(selected: on, child: body);
  }
}

/// 导航项右侧的计数角标：「节点」= 叶子节点数，「动态」= 连接数；0 不显示。
class _NavBadge extends ConsumerWidget {
  const _NavBadge(this.tab, {required this.active});
  final MeowTab tab;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = switch (tab) {
      MeowTab.proxies => ref.watch(leafNodeCountProvider),
      _ => ref.watch(connStatsProvider.select((s) => s.total)),
    };
    if (count <= 0) return const SizedBox.shrink();
    final cs = context.cs;
    final dark = context.isDarkMode;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
      decoration: BoxDecoration(
        color: active
            ? cs.primary.withValues(alpha: dark ? 0.24 : 0.14)
            : cs.surfaceContainerHighest.withValues(alpha: dark ? 0.7 : 0.9),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        count > 999 ? '999+' : '$count',
        textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
        style: MeowFont.mono(size: 10.5, weight: FontWeight.w700, color: active ? cs.primary : cs.onSurfaceVariant),
      ),
    );
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

/// 侧栏底部的常驻连接微控制台：统一实底 + 极细描边，已连接时以柔和绿点与淡色细边提示，不整块突兀变色。
class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard({required this.onOpenNodes});
  final VoidCallback onOpenNodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final mm = context.mm;
    final dark = context.isDarkMode;
    final phase = ref.watch(connPhaseProvider);
    final on = phase == ConnPhase.on;
    final mode = ref.watch(patchClashConfigProvider.select((s) => s.mode));
    final seconds = ref.watch(runTimeProvider.select((t) => t == null ? null : t ~/ 1000));
    final node = ref.watch(currentNodeProvider);
    final (label, dot) = switch (phase) {
      ConnPhase.on => ('已连接', mm.good),
      ConnPhase.connecting => ('连接中', mm.mid),
      ConnPhase.off => ('未连接', cs.onSurfaceVariant),
    };
    final sub = on && seconds != null
        ? '${modeLabel(mode)} · ${fmtUptime(Duration(seconds: seconds))}'
        : (ref.watch(hasProfileProvider) ? '${modeLabel(mode)}模式 · 已就绪' : '还没有订阅');
    final nodeName = switch (mode) {
      Mode.direct => '直连',
      _ => (node == null || node.leaf.isEmpty)
          ? (node?.group ?? (ref.watch(initProvider) ? '没有代理组' : '正在加载…'))
          : node.leaf,
    };

    return AnimatedContainer(
      duration: MeowMotion.of(context, const Duration(milliseconds: 220)),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: on
            ? (dark ? Color.alphaBlend(mm.good.withValues(alpha: 0.08), cs.cardInner) : Color.alphaBlend(mm.good.withValues(alpha: 0.06), cs.cardInner))
            : cs.cardInner,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: on ? mm.good.withValues(alpha: dark ? 0.32 : 0.28) : cs.cardBorder,
          width: 0.85,
        ),
      ),
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
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: cs.onSurface),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MeowPowerButton(
                size: 42,
                on: on,
                busy: phase == ConnPhase.connecting,
                enabled: ref.watch(powerEnabledProvider),
                onTap: () => unawaited(ref.read(powerProvider.notifier).toggle()),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Material(
            color: cs.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: cs.cardBorder, width: 0.7),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpenNodes,
              child: Container(
                constraints: const BoxConstraints(minHeight: 34),
                padding: const EdgeInsets.symmetric(horizontal: 9),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        nodeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface),
                      ),
                    ),
                    MeowIcon(MeowGlyph.chevron, size: 12, color: cs.onSurfaceVariant),
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

/// TUN / 系统代理：桌面端常驻双胶囊开关（柔和通透选中态 + 细边）。
class _TakeoverToggles extends ConsumerWidget {
  const _TakeoverToggles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final mm = context.mm;
    final dark = context.isDarkMode;
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
          child: AnimatedContainer(
            duration: MeowMotion.of(context, const Duration(milliseconds: 180)),
            decoration: BoxDecoration(
              gradient: value
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark
                          ? [Colors.white.withValues(alpha: 0.16), cs.primary.withValues(alpha: 0.24)]
                          : [cs.primary.withValues(alpha: 0.14), cs.primary.withValues(alpha: 0.08)],
                    )
                  : null,
              color: value ? null : cs.card,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                color: value
                    ? (dark ? Colors.white.withValues(alpha: 0.28) : cs.primary.withValues(alpha: 0.34))
                    : cs.cardBorder,
                width: value ? 0.95 : 0.7,
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 30),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (warn) ...[
                        Icon(Icons.error_outline_rounded, size: 12.5, color: value ? cs.primary : mm.mid),
                        const SizedBox(width: 3),
                      ],
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: value ? FontWeight.w700 : FontWeight.w600,
                            color: value ? (dark ? Colors.white : cs.primary) : cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
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
