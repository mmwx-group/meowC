import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'haptics.dart';
import 'm3.dart';
import 'tokens.dart';

/// Material 3 Expressive 的元件（2026-11 改版，样子以画布稿为准：首页 / 节点 / 动态 / 我的四张）。
/// 颜色一律取 `context.cs` / `context.m3`，形状取 [MeowShape]，形状变化走 [MeowSprings] 的回弹曲线。

/// 卡片：实色容器（缺省 [MeowCardColors.card]、圆角 28）。[borderRadius] 给了就用它（并排的两张卡片做不对称圆角时）。
class M3Card extends StatelessWidget {
  const M3Card({
    super.key,
    required this.child,
    this.color,
    this.radius = MeowShape.xl,
    this.borderRadius,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 18),
    this.onTap,
  });

  final Widget child;
  final Color? color;
  final double radius;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = borderRadius ?? BorderRadius.circular(radius);
    final body = Padding(padding: padding, child: child);
    return Material(
      color: color ?? context.cs.card,
      borderRadius: r,
      clipBehavior: onTap == null ? Clip.none : Clip.antiAlias,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

/// 页面大标题（Expressive 的粗字重）+ 一行小字 + 右侧圆钮。
class M3PageHeader extends StatelessWidget {
  const M3PageHeader({super.key, required this.title, this.subtitle, this.actions = const [], this.leading});

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: subtitle == null ? 30 : 28,
                    height: 1.15,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                    color: cs.onSurface,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: MeowFont.footnote,
                      color: cs.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
          for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), a],
        ],
      ),
    );
  }
}

/// 圆形图标钮（48）：缺省是 surfaceContainerHighest 底（画布稿的 `.ibtn`），[tonal] = 次色容器、[tertiary] = 第三色容器。
class M3IconButton extends StatelessWidget {
  const M3IconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 48,
    this.tonal = false,
    this.tertiary = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final bool tonal, tertiary;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final (bg, fg) = tertiary
        ? (cs.tertiaryContainer, cs.onTertiaryContainer)
        : tonal
        ? (cs.secondaryContainer, cs.onSecondaryContainer)
        : (cs.surfaceContainerHighest, cs.onSurface);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: size,
            child: Icon(icon, size: size * 0.5, color: onPressed == null ? fg.withValues(alpha: 0.38) : fg),
          ),
        ),
      ),
    );
  }
}

/// 分组小标题（主色、粗字重），放在一段分段清单上面。
class M3SectionLabel extends StatelessWidget {
  const M3SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 8, 0, 2),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w700, color: context.cs.primary),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// 连接式按钮组（出站模式、连接 / 日志）：按钮之间隔 4，首尾外侧大圆角、内侧小圆角；选中的那个变成整颗胶囊、主色实心，
/// 圆角变化走弹簧回弹。[onSurfaceColor] = 没选中的按钮底（放在主卡上时用半透明白，缺省 surfaceContainerHighest）。
class M3ButtonGroup<T> extends StatelessWidget {
  const M3ButtonGroup({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.height = 48,
    this.unselectedColor,
    this.dimmed = const {},
  });

  final List<(T value, String label)> items;
  final T? selected;
  final ValueChanged<T>? onChanged;
  final double height;
  final Color? unselectedColor;

  /// 画成次级字的项（如当前不可用的模式），仍然可点
  final Set<T> dimmed;

  static const gap = 4.0;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final outer = height / 2;
    const inner = MeowShape.s;
    return Semantics(
      container: true,
      child: Row(
        children: [
          for (final (i, (value, label)) in items.indexed) ...[
            if (i > 0) const SizedBox(width: gap),
            Expanded(
              child: _GroupButton(
                label: label,
                selected: value == selected,
                height: height,
                radius: value == selected
                    ? BorderRadius.circular(outer)
                    : BorderRadius.horizontal(
                        left: Radius.circular(i == 0 ? outer : inner),
                        right: Radius.circular(i == items.length - 1 ? outer : inner),
                      ),
                bg: value == selected ? cs.primary : (unselectedColor ?? cs.surfaceContainerHighest),
                fg: value == selected ? cs.onPrimary : (dimmed.contains(value) ? cs.onSurfaceVariant : cs.onSurface),
                onTap: onChanged == null || value == selected
                    ? null
                    : () {
                        MeowHaptics.select();
                        onChanged!(value);
                      },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupButton extends StatelessWidget {
  const _GroupButton({
    required this.label,
    required this.selected,
    required this.height,
    required this.radius,
    required this.bg,
    required this.fg,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final double height;
  final BorderRadius radius;
  final Color bg, fg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      // 形状与水波同一个裁切：水波 / 按下高亮裁在正在变形的形状里（以前 InkWell 按目标圆角画、不随形状裁，
      // 选中那一下按钮背后露出一块方角的灰底）。底色单独渐变，不让 AnimatedContainer 再对圆角插值一遍（会拖慢半拍）。
      child: TweenAnimationBuilder<BorderRadius?>(
        tween: BorderRadiusTween(end: radius),
        duration: MeowSprings.shapeDuration,
        curve: MeowSprings.shapeCurve,
        builder: (_, r, child) => ClipRRect(borderRadius: _nonNegative(r!), child: child),
        child: AnimatedContainer(
          duration: MeowSprings.effectsDuration,
          curve: MeowSprings.effectsCurve,
          height: height,
          color: bg,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              child: Center(
                child: AnimatedDefaultTextStyle(
                  duration: MeowSprings.effectsDuration,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: fg,
                    fontFamilyFallback: linuxTextFallback,
                  ),
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 回弹插值会让圆角短暂小于 0：夹住
BorderRadius _nonNegative(BorderRadius r) {
  Radius c(Radius x) => Radius.elliptical(math.max(0, x.x), math.max(0, x.y));
  return BorderRadius.only(
    topLeft: c(r.topLeft),
    topRight: c(r.topRight),
    bottomLeft: c(r.bottomLeft),
    bottomRight: c(r.bottomRight),
  );
}

/// 筛选 chip：没选中是描边方角（12），选中变成次色容器底、圆角变大（形状随弹簧变）。[icon] 只在选中时画（勾）。
class M3FilterChip extends StatelessWidget {
  const M3FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.height = 36,
    this.showCheck = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final double height;

  /// 选中时前面画一个勾（代理组 chip）
  final bool showCheck;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final r = selected ? height / 2 : MeowShape.m;
    return Semantics(
      button: true,
      selected: selected,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: r),
        duration: MeowSprings.shapeDuration,
        curve: MeowSprings.shapeCurve,
        // 水波裁在正在变形的形状里（同 [M3ButtonGroup]）
        builder: (_, radius, child) => ClipRRect(
          borderRadius: BorderRadius.circular(math.max(0, radius)),
          child: AnimatedContainer(
            duration: MeowSprings.effectsDuration,
            height: height,
            decoration: BoxDecoration(
              color: selected ? cs.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(math.max(0, radius)),
              border: Border.all(color: selected ? Colors.transparent : cs.outlineVariant),
            ),
            child: child,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap == null
                ? null
                : () {
                    MeowHaptics.select();
                    onTap!();
                  },
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: height > 38 ? 14 : 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showCheck && selected) ...[
                    Icon(Icons.check_rounded, size: 18, color: cs.onSecondaryContainer),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: height > 38 ? MeowFont.subheadline : MeowFont.footnote,
                      fontWeight: FontWeight.w600,
                      color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 图标块（清单行开头 40×40）：几种不同形状交替用，Expressive 的「形状多样」——圆、圆角方块、两种不对称圆角。
enum M3TileShape { circle, rounded, leafA, leafB }

class M3IconTile extends StatelessWidget {
  const M3IconTile({
    super.key,
    this.icon,
    this.text,
    this.child,
    this.shape = M3TileShape.rounded,
    required this.bg,
    required this.fg,
    this.size = 40,
  });

  final IconData? icon;
  final String? text;
  final Widget? child;
  final M3TileShape shape;
  final Color bg, fg;
  final double size;

  static BorderRadius radiusOf(M3TileShape shape, double size) => switch (shape) {
    M3TileShape.circle => BorderRadius.circular(size / 2),
    M3TileShape.rounded => BorderRadius.circular(size * 0.35),
    M3TileShape.leafA => BorderRadius.only(
      topLeft: Radius.circular(size * 0.3),
      bottomRight: Radius.circular(size * 0.3),
      topRight: Radius.circular(size * 0.5),
      bottomLeft: Radius.circular(size * 0.5),
    ),
    M3TileShape.leafB => BorderRadius.only(
      topLeft: Radius.circular(size * 0.5),
      bottomRight: Radius.circular(size * 0.5),
      topRight: Radius.circular(size * 0.3),
      bottomLeft: Radius.circular(size * 0.3),
    ),
  };

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<BorderRadius?>(
    tween: BorderRadiusTween(end: radiusOf(shape, size)),
    duration: MeowSprings.shapeDuration,
    curve: MeowSprings.shapeCurve,
    builder: (_, r, child) => AnimatedContainer(
      duration: MeowSprings.effectsDuration,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: _nonNegative(r!)),
      child: child,
    ),
    child:
        child ??
        (icon != null
            ? Icon(icon, size: size * 0.55, color: fg)
            : Text(
                text ?? '',
                maxLines: 1,
                // 国旗按 emoji 画大一点，字母 / 汉字照旧
                style: TextStyle(fontSize: size * (_isFlag(text) ? 0.5 : 0.33), fontWeight: FontWeight.w800, color: fg),
              )),
  );
}

/// 分段清单：一组连着的行，行间隔 3，首尾外侧大圆角（24）、中间小圆角（6）。每一行是 [M3ListRow]，它按自己在组里的位置取圆角。
class M3SegmentedList extends StatelessWidget {
  const M3SegmentedList({super.key, required this.children, this.gap = 3});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, c) in children.indexed) ...[
        if (i > 0) SizedBox(height: gap),
        M3SegmentSlot(index: i, count: children.length, child: c),
      ],
    ],
  );
}

/// 一行在分段清单里的位置（第 [index] / [count] 行）。[M3SegmentedList] 自动套；懒加载的长清单（SliverList）逐行自己套。
class M3SegmentSlot extends InheritedWidget {
  const M3SegmentSlot({super.key, required this.index, required this.count, required super.child});

  final int index, count;

  static M3SegmentSlot? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<M3SegmentSlot>();

  @override
  bool updateShouldNotify(M3SegmentSlot old) => old.index != index || old.count != count;
}

/// 清单的一行：开头图标块、标题 + 小字、行尾。在 [M3SegmentedList] 里按位置取分段圆角；单独用时四角都是大圆角。
/// [selected] = 次色容器底、四角变成 28（画布稿里选中的节点行），形状随弹簧变。
class M3ListRow extends StatelessWidget {
  const M3ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.color,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 2,
    this.titleSize = 16,
  });

  final String title;
  final String? subtitle;
  final Widget? leading, trailing;
  final bool selected;
  final VoidCallback? onTap, onLongPress;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final int titleMaxLines, subtitleMaxLines;
  final double titleSize;

  static const outer = 24.0, inner = 6.0, selectedRadius = MeowShape.xl;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final pos = M3SegmentSlot.maybeOf(context);
    final radius = selected
        ? BorderRadius.circular(selectedRadius)
        : pos == null
        ? BorderRadius.circular(outer)
        : MeowShape.segment(pos.index, pos.count, outer: outer, inner: inner);
    final fg = selected ? cs.onSecondaryContainer : cs.onSurface;
    final sub = selected ? cs.onSecondaryContainer.withValues(alpha: 0.85) : cs.onSurfaceVariant;
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: TweenAnimationBuilder<BorderRadius?>(
        tween: BorderRadiusTween(end: radius),
        duration: MeowSprings.shapeDuration,
        curve: MeowSprings.shapeCurve,
        builder: (_, r, child) {
          final rr = _nonNegative(r!);
          return AnimatedContainer(
            duration: MeowSprings.effectsDuration,
            decoration: BoxDecoration(
              color: selected ? cs.secondaryContainer : (color ?? cs.card),
              borderRadius: rr,
            ),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: rr,
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          );
        },
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: padding,
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 14)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: titleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w700, color: fg),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            subtitle!,
                            maxLines: subtitleMaxLines,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: MeowFont.caption, color: sub),
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 10), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 状态小胶囊（延迟、标签）：[tone] 决定配色——通 = 绿容器、慢 = 琥珀容器、超时 / 中性 = 次级底。
enum M3Tone { ok, warn, error, neutral, primary }

class M3Badge extends StatelessWidget {
  const M3Badge(this.text, {super.key, this.tone = M3Tone.neutral, this.fontSize = 12});

  final String text;
  final M3Tone tone;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs, x = context.m3;
    final (bg, fg) = switch (tone) {
      M3Tone.ok => (x.okContainer, x.onOkContainer),
      M3Tone.warn => (x.warnContainer, x.onWarnContainer),
      M3Tone.error => (cs.errorContainer, cs.onErrorContainer),
      M3Tone.primary => (cs.primaryContainer, cs.onPrimaryContainer),
      M3Tone.neutral => (cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: fontSize * 0.85, vertical: fontSize * 0.4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(MeowShape.full)),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          color: fg,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 极坐标形状：[lobes] 个圆润凸起的「饼干」（M3E 形状库的 Cookie / Clover），[depth] = 凹进去多深（相对半径）。
/// [squareness] = 0 是饼干、1 是圆角方块（超椭圆，指数 4.5），两者之间按半径线性插值（电源键另用 [meowPowerShape]）。
Path meowPolarShape(
  Size size, {
  required int lobes,
  required double depth,
  double squareness = 0,
  double rotation = 0,
  int samples = 240,
}) {
  final c = size.center(Offset.zero);
  final rMax = size.shortestSide / 2;
  final path = Path();
  for (var i = 0; i <= samples; i++) {
    final t = i / samples * 2 * math.pi;
    // 饼干：外沿 = rMax，凹处 = rMax·(1 − depth)
    final cookie = rMax * (1 - depth * (1 - math.cos(lobes * (t - rotation))) / 2);
    // 超椭圆（圆角方块），与饼干同样外接于 rMax
    const n = 4.5;
    final ct = math.cos(t).abs(), st = math.sin(t).abs();
    final square = rMax * math.pow(math.pow(ct, n) + math.pow(st, n), -1 / n) * 0.94;
    final r = cookie + (square - cookie) * squareness;
    final p = c + Offset(math.cos(t) * r, math.sin(t) * r);
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  return path..close();
}

class _PolarPainter extends CustomPainter {
  const _PolarPainter({
    required this.color,
    required this.lobes,
    required this.depth,
    required this.squareness,
    required this.rotation,
  });

  final Color color;
  final int lobes;
  final double depth, squareness, rotation;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    meowPolarShape(size, lobes: lobes, depth: depth, squareness: squareness.clamp(0.0, 1.0), rotation: rotation),
    Paint()
      ..color = color
      ..isAntiAlias = true,
  );

  @override
  bool shouldRepaint(_PolarPainter old) =>
      old.color != color ||
      old.lobes != lobes ||
      old.depth != depth ||
      old.squareness != squareness ||
      old.rotation != rotation;
}

/// 一块静止的饼干形色块（品牌头、头像底）。
class M3Cookie extends StatelessWidget {
  const M3Cookie({super.key, required this.size, required this.color, this.lobes = 4, this.depth = 0.22, this.child});

  final double size;
  final Color color;
  final int lobes;
  final double depth;
  final Widget? child;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _PolarPainter(color: color, lobes: lobes, depth: depth, squareness: 0, rotation: -math.pi / 2),
      child: child == null ? null : Center(child: child),
    ),
  );
}

/// 电源键（M3E 的饼干形按钮）：已连接 = 主色八瓣饼干、白色图标；没连 = 圆角方块、最浅的底、主色图标；
/// 连接 / 断开中是半开的花瓣慢慢转（同 M3E 的加载指示器）。
///
/// 形变（2026-11-17 用户在四个方案里选的「A 同族八瓣」，以前是九瓣 ↔ 方块直接按半径插值）：
/// - 八瓣：方块每条边正好变成两瓣，整个过程保持四重对称（九瓣对四个角，中间形状歪、鼓包）；
/// - 两个量分开走：[_morph] 方块 ↔ 圆（阻尼比 0.62，几乎不冲过头），[_depth] 花瓣深浅（阻尼比 0.45，开花时回弹一下）；
///   连接中花瓣只开一半，连上再全开；
/// - 形变时顺带转 1/16 圈，方块与花外沿差不多大（以前方块小 6%，大小会跳）；
/// - 转动停下时对齐到 1/4 圈：之后再变回方块是正的，不会斜着。
class M3PowerButton extends StatefulWidget {
  const M3PowerButton({
    super.key,
    required this.on,
    required this.busy,
    required this.onTap,
    this.size = 116,
    this.enabled = true,
  });

  final bool on, busy, enabled;
  final VoidCallback onTap;
  final double size;

  @override
  State<M3PowerButton> createState() => _M3PowerButtonState();
}

class _M3PowerButtonState extends State<M3PowerButton> with TickerProviderStateMixin {
  // 方块 ↔ 圆：1 = 圆角方块（没连），0 = 圆（已连 / 正在连，花瓣深浅由 _depth 定）
  late final AnimationController _morph = AnimationController.unbounded(vsync: this, value: _morphTarget);
  // 花瓣深浅：0 = 没有花瓣，0.45 = 连接中半开，1 = 已连全开
  late final AnimationController _depth = AnimationController.unbounded(vsync: this, value: _depthTarget);
  // 转动：忙的时候一直转（一圈 5.2 秒），停下时转到最近的 1/4 圈
  late final AnimationController _spin = AnimationController(vsync: this, duration: _spinTurn);

  static const _spinTurn = Duration(milliseconds: 5200);
  static final _morphSpring = SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.62);
  static final _depthSpring = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.45);

  double get _morphTarget => widget.on || widget.busy ? 0 : 1;
  double get _depthTarget => widget.on ? 1 : (widget.busy ? 0.45 : 0);

  @override
  void initState() {
    super.initState();
    if (widget.busy) _spin.repeat();
  }

  void _springTo(AnimationController c, double target, SpringDescription spring) {
    if (c.value == target && !c.isAnimating) return;
    // 弹簧停下时离目标还差一点点（容差内就算停）：正常结束后对齐到目标，颜色才是准的；被新目标打断时不会走到这里
    c.animateWith(SpringSimulation(spring, c.value, target, c.velocity)).then((_) {
      if (mounted) c.value = target;
    });
  }

  @override
  void didUpdateWidget(M3PowerButton old) {
    super.didUpdateWidget(old);
    _springTo(_morph, _morphTarget, _morphSpring);
    _springTo(_depth, _depthTarget, _depthSpring);
    if (widget.busy && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.busy && _spin.isAnimating) {
      // 转到下一个 1/4 圈停下：八瓣与方块都对齐，不突然跳回
      const step = 0.25;
      final end = ((_spin.value / step).ceil() * step).clamp(0.0, 1.0);
      final ms = ((end - _spin.value) * _spinTurn.inMilliseconds).round() + 1;
      _spin.animateTo(end, duration: Duration(milliseconds: ms)).then((_) {
        if (mounted && !widget.busy) _spin.value = 0;
      });
    }
  }

  @override
  void dispose() {
    _morph.dispose();
    _depth.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final size = widget.size;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.on ? '断开连接' : (widget.busy ? '正在连接' : '连接'),
      child: Opacity(
        opacity: widget.enabled || widget.busy ? 1 : 0.38,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled
              ? () {
                  MeowHaptics.toggle();
                  widget.onTap();
                }
              : null,
          child: SizedBox.square(
            dimension: size,
            child: AnimatedBuilder(
              animation: Listenable.merge([_morph, _depth, _spin]),
              builder: (_, _) {
                final m = (reduce ? _morphTarget : _morph.value).clamp(0.0, 1.0);
                final d = reduce ? _depthTarget : _depth.value;
                final fill = Color.lerp(cs.primary, cs.surfaceContainerLowest, m)!;
                final iconColor = Color.lerp(cs.onPrimary, cs.primary, m)!;
                return CustomPaint(
                  painter: _PowerShapePainter(
                    color: fill,
                    morph: m,
                    depth: d,
                    rotation: (reduce ? 0 : _spin.value * 2 * math.pi) + (1 - m) * math.pi / 8,
                  ),
                  child: Center(
                    child: Icon(Icons.power_settings_new_rounded, size: size * 0.36, color: iconColor),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 电源键的形状：八瓣饼干与圆角方块（超椭圆，指数 4.5）按半径插值，见 [M3PowerButton]。
/// 饼干外沿 = 半径（花瓣全开时凹处 87%），没开花时略收 3%；方块边的中点在 90%，四个角圆润外凸，两者看着差不多大。
@visibleForTesting
Path meowPowerShape(Size size, {required double morph, required double depth, double rotation = 0, int samples = 240}) {
  final c = size.center(Offset.zero);
  final rMax = size.shortestSide / 2;
  const n = 4.5;
  final path = Path();
  for (var i = 0; i <= samples; i++) {
    final t = i / samples * 2 * math.pi;
    final a = t - rotation;
    final cookie = (1 - 0.13 * depth * (1 - math.cos(8 * a)) / 2) * (1 - 0.03 * (1 - depth));
    final ct = math.cos(a).abs(), st = math.sin(a).abs();
    final square = math.pow(math.pow(ct, n) + math.pow(st, n), -1 / n) * 0.9;
    final r = rMax * (cookie + (square - cookie) * morph);
    final p = c + Offset(math.cos(t) * r, math.sin(t) * r);
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  return path..close();
}

class _PowerShapePainter extends CustomPainter {
  const _PowerShapePainter({required this.color, required this.morph, required this.depth, required this.rotation});

  final Color color;
  final double morph, depth, rotation;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    meowPowerShape(size, morph: morph, depth: depth, rotation: rotation),
    Paint()
      ..color = color
      ..isAntiAlias = true,
  );

  @override
  bool shouldRepaint(_PowerShapePainter old) =>
      old.color != color || old.morph != morph || old.depth != depth || old.rotation != rotation;
}

/// 波浪进度条（M3E）：已完成的一段画成正弦波，剩下的是直的轨道（中间隔一段空），末端一个主色小圆点。
/// [animate] = 波一直往前走（进行中），否则静止。
class M3WavyProgress extends StatefulWidget {
  const M3WavyProgress({
    super.key,
    required this.value,
    this.height = 12,
    this.stroke = 4,
    this.wavelength = 18,
    this.amplitude = 2.6,
    this.animate = false,
    this.color,
    this.trackColor,
  });

  final double value;
  final double height, stroke, wavelength, amplitude;
  final bool animate;
  final Color? color, trackColor;

  @override
  State<M3WavyProgress> createState() => _M3WavyProgressState();
}

class _M3WavyProgressState extends State<M3WavyProgress> with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _phase.repeat();
  }

  @override
  void didUpdateWidget(M3WavyProgress old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_phase.isAnimating) _phase.repeat();
    if (!widget.animate && _phase.isAnimating) _phase.stop();
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Semantics(
      value: '${(widget.value.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox(
        height: widget.height,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: widget.value.clamp(0.0, 1.0)),
          duration: MeowSprings.shapeDuration,
          curve: MeowSprings.effectsCurve,
          builder: (_, v, _) => AnimatedBuilder(
            animation: _phase,
            builder: (_, _) => CustomPaint(
              size: Size.infinite,
              painter: _WavyPainter(
                value: v,
                phase: _phase.value,
                stroke: widget.stroke,
                wavelength: widget.wavelength,
                amplitude: widget.amplitude,
                color: widget.color ?? cs.primary,
                track: widget.trackColor ?? cs.secondaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavyPainter extends CustomPainter {
  const _WavyPainter({
    required this.value,
    required this.phase,
    required this.stroke,
    required this.wavelength,
    required this.amplitude,
    required this.color,
    required this.track,
  });

  final double value, phase, stroke, wavelength, amplitude;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final left = stroke / 2, right = size.width - stroke / 2;
    final w = right - left;
    final end = left + w * value;
    const gap = 8.0;
    final paint = Paint()
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // 轨道：从已完成那段后面隔一段开始，到末端圆点前面
    final dot = stroke * 0.65;
    final trackStart = value <= 0 ? left : end + gap;
    final trackEnd = right - dot * 2 - 4;
    if (trackEnd > trackStart) {
      canvas.drawLine(Offset(trackStart, cy), Offset(trackEnd, cy), paint..color = track);
    }
    canvas.drawCircle(Offset(right - dot, cy), dot, Paint()..color = color);
    if (value <= 0) return;
    // 已完成：正弦波，两端振幅收到 0（起止平顺）
    final path = Path()..moveTo(left, cy);
    final ramp = math.min(wavelength, (end - left) / 2);
    for (var x = left; x <= end; x += 1) {
      final edge = ramp <= 0 ? 0.0 : math.min(1.0, math.min(x - left, end - x) / ramp);
      final y = cy + math.sin((x - left) / wavelength * 2 * math.pi - phase * 2 * math.pi) * amplitude * edge;
      path.lineTo(x, y);
    }
    path.lineTo(end, cy);
    canvas.drawPath(path, paint..color = color);
  }

  @override
  bool shouldRepaint(_WavyPainter old) =>
      old.value != value || old.phase != phase || old.color != color || old.track != track;
}

/// 扩展式悬浮按钮（全部测速）：第三色容器、圆角 20、高 64。[busy] 时图标换成转圈。
class M3ExtendedFab extends StatelessWidget {
  const M3ExtendedFab({super.key, required this.icon, required this.label, required this.onPressed, this.busy = false});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Material(
      color: cs.tertiaryContainer,
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(MeowShape.lInc),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 22, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 24,
                  child: busy
                      ? Padding(
                          padding: const EdgeInsets.all(2),
                          child: CircularProgressIndicator(strokeWidth: 2.6, color: cs.onTertiaryContainer),
                        )
                      : Icon(icon, color: cs.onTertiaryContainer),
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: cs.onTertiaryContainer),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _isFlag(String? text) {
  if (text == null) return false;
  final r = text.runes.toList();
  return r.length == 2 && r.every((c) => c >= 0x1F1E6 && c <= 0x1F1FF);
}
