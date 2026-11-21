import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/common/delay_test.dart';
import 'package:bett_box/meowx/theme/target_icon.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../state/format.dart';
import '../../state/meow_settings.dart';
import '../../theme/haptics.dart';
import '../../theme/latency_badge.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/motion.dart';
import '../../theme/badges.dart';
import '../../theme/tokens.dart';
import 'node_grid.dart';
import 'node_parts.dart';

/// 单组布局顶部的代理组 chip（画布稿 Nodes）：一排横向滚动的筛选 chip，选中的带勾、变成胶囊；换组时把选中的那个滚进视野。
/// [padding] = 页面左右留白：滚动区本身贴到屏幕两边，chip 滚出去时不在留白处被裁掉。
class GroupChipBar extends StatefulWidget {
  const GroupChipBar({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
    this.padding = EdgeInsets.zero,
  });

  final List<Group> groups;
  final String selected;
  final ValueChanged<String> onSelected;
  final EdgeInsets padding;

  @override
  State<GroupChipBar> createState() => _GroupChipBarState();
}

class _GroupChipBarState extends State<GroupChipBar> {
  final _keys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _reveal(animate: false);
  }

  @override
  void didUpdateWidget(GroupChipBar old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _reveal(animate: true);
  }

  void _reveal({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[widget.selected]?.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: animate && !MeowMotion.reduced(context) ? const Duration(milliseconds: 300) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.only(left: widget.padding.left, right: widget.padding.right),
      itemCount: widget.groups.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (_, i) {
        final g = widget.groups[i];
        final on = g.name == widget.selected;
        return M3FilterChip(
          key: _keys.putIfAbsent(g.name, GlobalKey.new),
          label: g.name,
          selected: on,
          showCheck: true,
          height: 40,
          onTap: on ? null : () => widget.onSelected(g.name),
        );
      },
    ),
  );
}

/// 测速本组 + 组延迟合成一个钮（与 iOS / macOS 的 LatencyTestButton 一致）：没测过是闪电（摘要卡的胶囊带「测速」二字），
/// 测过显示组延迟（= 当前选中节点的延迟，色阶同 [MsChip]），测速中转圈；点一下重新测本组。
/// 默认是摘要卡里的胶囊，[compact] = 列表布局组卡上奶白胶囊。
class GroupTestButton extends ConsumerWidget {
  const GroupTestButton({super.key, required this.group, required this.delay, this.compact = false, this.height = 44});
  final Group group;

  /// 组延迟（getDelayProvider 同口径：null = 没测过，0 = 测试中，<0 = 超时）
  final int? delay;
  final bool compact;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final mode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    return ListenableBuilder(
      listenable: delayTestCoordinator,
      builder: (_, _) {
        final testing = delayTestCoordinator.isTestingGroup(group.name) || delay == 0;
        void run() {
          MeowHaptics.tap();
          delayTest(group.all, testUrl: group.testUrl, groupName: group.name);
        }

        // 测过：延迟色调容器（同节点行的延迟胶囊）；没测过 / 测速中：中性底 + 闪电「测速」/ 转圈
        final tone = testing || delay == null ? M3Tone.neutral : latencyTone(delay, mode);
        final (bg, fg) = switch (tone) {
          M3Tone.ok => (context.m3.okContainer, context.m3.onOkContainer),
          M3Tone.warn => (context.m3.warnContainer, context.m3.onWarnContainer),
          M3Tone.error => (cs.errorContainer, cs.onErrorContainer),
          _ => (compact ? cs.surfaceContainerHighest : cs.surfaceContainerLowest.withValues(alpha: 0.7), cs.onSurface),
        };
        final Widget content;
        if (testing) {
          content = SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary));
        } else if (delay == null) {
          final bolt = Icon(Icons.bolt_rounded, size: 18, color: cs.primary);
          content = compact
              ? bolt
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    bolt,
                    const SizedBox(width: 2),
                    Text('测速', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
                  ],
                );
        } else {
          content = Text(
            LatencyBadge.text(delay, unit: !compact),
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              fontWeight: FontWeight.w800,
              color: fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
        }
        return Tooltip(
          message: S.testGroup,
          child: Material(
            color: bg,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: testing ? null : run,
              child: Container(
                constraints: BoxConstraints(minWidth: compact ? 44 : 64, minHeight: compact ? 30 : height),
                padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
                alignment: Alignment.center,
                child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: content),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 组卡：两处用。
/// - 宽屏左栏的一行（分段清单的行：组图标块 + 名 / 当前选中 + 组延迟；[selected] = 次色容器底、四角 28）；
/// - 手机列表布局里可展开的组头（[expanded] 非 null）：多画类型 · 成员数、测速钮和箭头，展开时换成主色容器底，下面接节点。
class GroupCard extends ConsumerWidget {
  const GroupCard({super.key, required this.group, required this.onTap, this.selected = false, this.expanded});
  final Group group;
  final VoidCallback onTap;
  final bool selected;
  final bool? expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final dark = context.isDarkMode;
    final current = ref.watch(getSelectedProxyNameProvider(group.name)) ?? '';
    final mode = ref.watch(meowSettingProvider.select((s) => s.latencyMode));
    final delay = current.isEmpty ? null : ref.watch(getDelayProvider(proxyName: current, testUrl: group.testUrl));
    const darkMonograms = [
      (Color(0xFF2D1E28), Color(0xFFFF9AB8)),
      (Color(0xFF1A2A36), Color(0xFF7CC8F8)),
      (Color(0xFF1A2D24), Color(0xFF6EE7B7)),
      (Color(0xFF262138), Color(0xFFC4B5FD)),
    ];
    const lightMonograms = [
      (Color(0xFFFCE8F1), Color(0xFFB8326A)),
      (Color(0xFFE7F3FE), Color(0xFF1D6FA5)),
      (Color(0xFFE6F7F0), Color(0xFF1D7A58)),
      (Color(0xFFF0ECFE), Color(0xFF5D46A8)),
    ];
    final palette = dark ? darkMonograms : lightMonograms;
    final (monoBg, monoFg) = palette[group.name.hashCode.abs() % palette.length];
    final tile = M3IconTile(
      shape: selected || expanded == true ? M3TileShape.circle : M3TileShape.rounded,
      bg: selected || expanded == true ? cs.primary : monoBg,
      fg: selected || expanded == true ? cs.onPrimary : monoFg,
      text: group.icon.isEmpty ? nodeTileLabel(group.name) : null,
      child: group.icon.isEmpty ? null : CommonTargetIcon(src: group.icon, size: 22),
    );
    if (expanded != null) return _listCard(context, tile, current, delay, expanded!);
    return M3ListRow(
      title: group.icon.isEmpty ? nodeTitleWithoutFlag(group.name) : group.name,
      titleSize: 15,
      // 同 iOS：类型徽标跟在组名后面（主题色），组名下面写当前选中的节点（用户 2026-11-18）
      titleTrailing: GroupTypeTag(group: group, onSelected: selected),
      subtitle: current.isEmpty ? null : current,
      subtitleMaxLines: 1,
      selected: selected,
      onTap: onTap,
      leading: tile,
      trailing: current.isEmpty ? null : LatencyBadge(ms: delay, mode: mode, unit: false, fontSize: 12),
    );
  }

  /// 列表布局的组卡：图标块 · 组名 / 策略 ……… 测速钮 · 展开钮（圆形按钮）。展开时主色容器底（同单组布局的摘要卡）。
  Widget _listCard(BuildContext context, Widget tile, String current, int? delay, bool open) {
    final cs = context.cs;
    final fg = open ? cs.onPrimaryContainer : cs.onSurface;
    final sub = open ? cs.onPrimaryContainer.withValues(alpha: 0.85) : cs.onSurfaceVariant;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: open ? MeowShape.xl : 24),
      duration: MeowSprings.shapeDuration,
      curve: MeowSprings.shapeCurve,
      builder: (_, r, child) => AnimatedContainer(
        duration: MeowSprings.effectsDuration,
        decoration: BoxDecoration(
          color: open ? cs.primaryContainer : cs.card,
          borderRadius: BorderRadius.circular(math.max(0, r)),
          border: Border.all(color: open ? cs.primary.withValues(alpha: 0.35) : cs.cardBorder, width: 0.8),
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(math.max(0, r)),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              tile,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 同 iOS：组名后面跟类型徽标（主题色），下面一行是当前选中的节点（用户 2026-11-18）
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            group.icon.isEmpty ? nodeTitleWithoutFlag(group.name) : group.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: fg),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GroupTypeTag(group: group, onSelected: open),
                      ],
                    ),
                    if (current.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          NestedGroupIcon(current, size: 14, gap: 4),
                          Flexible(
                            child: Text(
                              current,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w500, color: sub),
                            ),
                          ),
                          CurrentBadges(groupName: group.name),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GroupTestButton(group: group, delay: delay, compact: true),
              const SizedBox(width: 8),
              // 展开钮：一颗圆形按钮包着箭头（展开时主色实心），点它与点组卡同一个动作
              Material(
                color: open ? cs.primary : cs.cardInner,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: SizedBox.square(
                    dimension: 36,
                    child: Center(child: _GroupChevron(open: open, color: open ? cs.onPrimary : cs.onSurfaceVariant)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 代理组类型徽标：主题色等宽字、卡片次级底、圆角 8（同 iOS 的 GroupKindBadge，不按类型变色）。
/// [onSelected] = 所在的卡片是选中 / 展开的容器色底，徽标底换成卡片色。
class GroupTypeTag extends StatelessWidget {
  const GroupTypeTag({super.key, required this.group, this.onSelected = false});
  final Group group;
  final bool onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: onSelected ? cs.card : cs.cardInner,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        groupTypeLabel(group.type.name),
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: MeowFont.caption2,
          fontWeight: FontWeight.w600,
          color: cs.primary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 组卡上的箭头：收起朝下、展开朝上，转动用弹跳弹簧。初值按当前状态给：滚动回来 / 重建时不重播。
class _GroupChevron extends StatefulWidget {
  const _GroupChevron({required this.open, required this.color});
  final bool open;
  final Color color;

  @override
  State<_GroupChevron> createState() => _GroupChevronState();
}

class _GroupChevronState extends State<_GroupChevron> with SingleTickerProviderStateMixin {
  /// 0 = 朝下，1 = 朝上（转过 180°）
  late final _turn = AnimationController.unbounded(vsync: this, value: widget.open ? 1 : 0);

  @override
  void didUpdateWidget(_GroupChevron old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) {
      MeowMotion.spring(_turn, widget.open ? 1 : 0, MeowMotion.bouncy, reduce: MeowMotion.reduced(context));
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _turn,
    // 图形本身朝右：先转 90° 朝下，再按进度转到朝上
    // 同 iOS：收起朝右、展开转 90° 朝下（以前收起朝下、展开转 180° 朝上，和 iOS 不一致）
    builder: (_, child) => Transform.rotate(angle: _turn.value * math.pi / 2, child: child),
    child: Icon(Icons.chevron_right_rounded, color: widget.color),
  );
}

/// 当前组摘要（樱粉主卡；液态玻璃主题下和其它卡片一样是磨砂玻璃卡片）：类型 + 成员数 + 当前选中 + 延迟 + 测速；
/// url-test / fallback 组带「自动选择」开关，手选 = 固定。
/// 手机（单组布局组按钮下面）按 ANodes 排成两行；[wide] = 宽屏右栏，按 WNodes 排成一行并带组名。
class GroupSummary extends ConsumerWidget {
  const GroupSummary({super.key, required this.group, this.wide = false});
  final Group group;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final fg = cs.onPrimaryContainer;
    final computed = group.type.isComputedSelected;
    final fixed = watchFixedMember(ref, group);
    // 和节点的高亮同一口径：正在切换时先显示目标节点
    final pending = computed ? ref.watch(pendingPickProvider.select((m) => m[group.name])) : null;
    final current = (pending != null && pending.isNotEmpty)
        ? pending
        : (ref.watch(getSelectedProxyNameProvider(group.name)) ?? '');
    final delay = current.isEmpty ? null : ref.watch(getDelayProvider(proxyName: current, testUrl: group.testUrl));
    final type =
        '${groupTypeLabel(group.type.name)} · ${group.all.length}${computed ? (fixed.isEmpty ? ' · 自动' : ' · 已固定') : ''}';
    final typeTag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(MeowShape.full),
      ),
      child: Text(
        type,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.onSurface),
      ),
    );
    final currentRow = Row(
      children: [
        Text('当前', style: TextStyle(fontSize: 14, color: fg.withValues(alpha: 0.85))),
        const SizedBox(width: 10),
        NestedGroupIcon(current, size: 18),
        Flexible(
          child: Text(
            current.isEmpty ? '—' : current,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: fg),
          ),
        ),
        CurrentBadges(groupName: group.name),
        const Spacer(),
        const SizedBox(width: 8),
        GroupTestButton(group: group, delay: delay, height: 36),
      ],
    );

    return Container(
      padding: wide ? const EdgeInsets.fromLTRB(18, 14, 14, 14) : const EdgeInsets.fromLTRB(18, 18, 14, 16),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(wide ? MeowShape.xl : MeowShape.xlInc),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (group.icon.isNotEmpty) ...[CommonTargetIcon(src: group.icon, size: 24), const SizedBox(width: 8)],
              Expanded(
                child: Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: wide ? 20 : 22, fontWeight: FontWeight.w900, color: fg),
                ),
              ),
              const SizedBox(width: 10),
              // 窄屏 + 大字号放不下时整体缩小，组名先省略
              Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: typeTag)),
            ],
          ),
          const SizedBox(height: 12),
          currentRow,
        ],
      ),
    );
  }
}
