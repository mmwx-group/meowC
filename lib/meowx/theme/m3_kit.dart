import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'haptics.dart';
import 'm3.dart';
import 'motion.dart';
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

/// 滑块分段（同 iOS 的 MeowSegment，2026-11-18 用户要求首页模式与动态页分段换成它）：
/// 一条比卡片深一档的轨道（圆角 14、内边距 3）+ 一块选中滑块（圆角 11），换段时只有滑块弹簧平移过去（弹跳弹簧，同 iOS 的 MeowMotion.slide）。
/// 选中块用反色：浅色下深底浅字、深色下浅底深字（iOS 经典主题的 MM.strong / 深色的近白）。
/// 选中值由外面给：别处改的（引擎回报的模式、托盘）也一样滑过去。
class MeowSlideSegment<T> extends StatefulWidget {
  const MeowSlideSegment({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.height = 44,
    this.track,
    this.fontSize = 14,
    this.dimmed = const {},
  });

  final List<(T value, String label)> items;
  final T? selected;
  final ValueChanged<T>? onChanged;
  final double height;

  /// 轨道色；缺省比卡片深一档（cardInner）
  final Color? track;
  final double fontSize;

  /// 画成次级字的项（如当前不可用的模式），仍然可点
  final Set<T> dimmed;

  static const pad = 3.0, gap = 3.0, trackRadius = 14.0, thumbRadius = 11.0;

  @override
  State<MeowSlideSegment<T>> createState() => _MeowSlideSegmentState<T>();
}

class _MeowSlideSegmentState<T> extends State<MeowSlideSegment<T>> with SingleTickerProviderStateMixin {
  int get _index => widget.items.indexWhere((e) => e.$1 == widget.selected);

  /// 滑块位置（按段的序号，弹簧会稍微越过终点；画的时候夹在两端之间）
  late final _pos = AnimationController.unbounded(vsync: this, value: math.max(0, _index).toDouble());

  @override
  void didUpdateWidget(MeowSlideSegment<T> old) {
    super.didUpdateWidget(old);
    final i = _index;
    if (i >= 0 && i.toDouble() != _pos.value) {
      MeowMotion.spring(_pos, i.toDouble(), MeowMotion.bouncy, reduce: MeowMotion.reduced(context));
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final n = widget.items.length;
    final selected = _index;
    const p = MeowSlideSegment.pad, g = MeowSlideSegment.gap;
    return Semantics(
      container: true,
      child: Container(
        height: widget.height,
        padding: const EdgeInsets.all(p),
        decoration: BoxDecoration(
          color: widget.track ?? cs.cardInner,
          borderRadius: BorderRadius.circular(MeowSlideSegment.trackRadius),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final segW = n == 0 ? 0.0 : (c.maxWidth - g * (n - 1)) / n;
            return Stack(
              children: [
                if (selected >= 0)
                  AnimatedBuilder(
                    animation: _pos,
                    builder: (_, child) => Positioned(
                      left: _pos.value.clamp(0, (n - 1).toDouble()) * (segW + g),
                      top: 0,
                      bottom: 0,
                      width: segW,
                      child: child!,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.inverseSurface,
                        borderRadius: BorderRadius.circular(MeowSlideSegment.thumbRadius),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    for (final (i, (value, label)) in widget.items.indexed) ...[
                      if (i > 0) const SizedBox(width: g),
                      Expanded(child: _segment(context, i, value, label, i == selected)),
                    ],
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, int i, T value, String label, bool on) {
    final cs = context.cs;
    final onChanged = widget.onChanged;
    return Semantics(
      button: true,
      selected: on,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(MeowSlideSegment.thumbRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onChanged == null || on
              ? null
              : () {
                  MeowHaptics.select();
                  onChanged(value);
                },
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: MeowSprings.effectsDuration,
              style: TextStyle(
                fontSize: widget.fontSize,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                color: on
                    ? cs.onInverseSurface
                    : (widget.dimmed.contains(value) ? cs.outline : cs.onSurfaceVariant),
                fontFamilyFallback: linuxTextFallback,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
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
    this.footer,
    this.titleTrailing,
    this.titleLeading,
    this.subtitleWidget,
  });

  final String title;

  /// 紧跟在标题后面的小部件（节点页组卡的类型徽标）
  final Widget? titleTrailing;

  /// 紧挨在标题前面的小部件（动态页连接行的 TCP / UDP 小标）
  final Widget? titleLeading;

  /// 代替 [subtitle] 的一行（需要分段上色时用）
  final Widget? subtitleWidget;
  final String? subtitle;
  final Widget? leading, trailing;

  /// 副标题下面再一行（动态页连接行的「↓ ↑ 累计 · 时长」）
  final Widget? footer;
  final bool selected;
  final VoidCallback? onTap, onLongPress;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final int titleMaxLines, subtitleMaxLines;
  final double titleSize;

  // 分段清单里的每一行四角都是完整的大圆角（2026-11-18 用户要求，以前相邻行之间的内角只有 6，看着像直角）
  static const outer = 24.0, inner = outer, selectedRadius = MeowShape.xl;

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
            decoration: BoxDecoration(color: selected ? cs.secondaryContainer : (color ?? cs.card), borderRadius: rr),
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
                      if (titleTrailing == null && titleLeading == null)
                        Text(
                          title,
                          maxLines: titleMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w700, color: fg),
                        )
                      else
                        Row(
                          children: [
                            if (titleLeading != null) ...[titleLeading!, const SizedBox(width: 6)],
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w700, color: fg),
                              ),
                            ),
                            if (titleTrailing != null) ...[const SizedBox(width: 6), titleTrailing!],
                          ],
                        ),
                      if (subtitleWidget != null)
                        Padding(padding: const EdgeInsets.only(top: 2), child: subtitleWidget)
                      else if (subtitle != null && subtitle!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            subtitle!,
                            maxLines: subtitleMaxLines,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: MeowFont.caption, color: sub),
                          ),
                        ),
                      if (footer != null) Padding(padding: const EdgeInsets.only(top: 2), child: footer),
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

/// 电源键（2026-11-18 用户要求与 iOS 一致，照 iOS `PowerButton` 的经典样式；以前是 M3E 的饼干 ↔ 八瓣花、连上一直转）：
/// 圆角方块（圆角 = 边长 × 0.325，超椭圆）；没连 = 反色实心（浅色深底浅图标、深色浅底深图标，同 iOS 的墨色 / 近白）；
/// 连接过程是「液面上升」：连接中樱粉从底部注入——先快后慢，1.2 秒到七成，之后 6 秒慢慢涨到九成（规则集拉得久、核心起得慢也不会注满了还没连上）；
/// 连上那一刻补满（弹跳弹簧）、外扩一圈同形描边涟漪、图标转深色；断开或连接失败时排空。
/// 樱粉 = 主题主色的色相，浅色亮度 70%、深色 80%（同 iOS 的 heroShades），连上时带一圈同色投影。
/// 液面只是一块按比例纵向缩放的色块（锚在底边），不触发布局。系统「移除动画」时直接跳到位。
class M3PowerButton extends StatefulWidget {
  const M3PowerButton({
    super.key,
    required this.on,
    required this.busy,
    required this.onTap,
    this.size = 80,
    this.enabled = true,
  });

  final bool on, busy, enabled;
  final VoidCallback onTap;
  final double size;

  /// 已连接的填充色（樱粉）：主色的色相，饱和度夹在 0.35–0.78，浅色亮度 70%、深色 80%（同 iOS）
  static Color activeFill(ColorScheme cs) {
    final hsl = HSLColor.fromColor(cs.primary);
    final s = hsl.saturation < 0.08 ? hsl.saturation : hsl.saturation.clamp(0.35, 0.78);
    return hsl.withSaturation(s).withLightness(cs.brightness == Brightness.dark ? 0.80 : 0.70).toColor();
  }

  /// 连上时图标的深色（同 iOS #2A2130）
  static const activeIcon = Color(0xFF2A2130);

  @override
  State<M3PowerButton> createState() => _M3PowerButtonState();
}

class _M3PowerButtonState extends State<M3PowerButton> with TickerProviderStateMixin {
  /// 液面高度 0…1：初值按出现时的状态给（切回首页时已连接就是满的，不再从零注一遍）
  late final AnimationController _level = AnimationController.unbounded(vsync: this, value: widget.on ? 1 : 0);

  /// 连上那一刻外扩一次的涟漪（0 → 1：放大 1 → 1.5、透明度 0.8 → 0）
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
    value: 1,
  );

  bool _pressed = false;
  int _pourId = 0;

  static final _fillSpring = SpringDescription.withDampingRatio(mass: 1, stiffness: 260, ratio: 0.5);

  bool get _reduce => MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 连接中切回首页：接着注
    if (widget.busy && !widget.on && _level.value == 0 && !_level.isAnimating) _pour();
  }

  @override
  void didUpdateWidget(M3PowerButton old) {
    super.didUpdateWidget(old);
    if (old.on != widget.on || old.busy != widget.busy) _pour();
  }

  void _pour() {
    final id = ++_pourId;
    if (_reduce) {
      _level.value = widget.on ? 1 : (widget.busy ? 0.7 : 0);
      return;
    }
    if (widget.on) {
      _level.animateWith(SpringSimulation(_fillSpring, _level.value, 1, _level.velocity)).then((_) {
        if (mounted && id == _pourId) _level.value = 1;
      });
      _ripple.forward(from: 0);
    } else if (widget.busy) {
      _level.animateTo(0.7, duration: const Duration(milliseconds: 1200), curve: const Cubic(0.2, 0.8, 0.3, 1)).then((_) {
        if (mounted && id == _pourId) _level.animateTo(0.92, duration: const Duration(seconds: 6), curve: Curves.linear);
      });
    } else {
      _level.animateTo(0, duration: const Duration(milliseconds: 350), curve: const Cubic(0.5, 0, 0.8, 0.4));
    }
  }

  @override
  void dispose() {
    _level.dispose();
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final size = widget.size;
    final enabled = widget.enabled;
    final active = M3PowerButton.activeFill(cs);
    final shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(size * 0.325));
    final idleFill = enabled ? cs.inverseSurface : cs.cardInner;
    final iconColor = !enabled ? cs.outline : (widget.on ? M3PowerButton.activeIcon : cs.onInverseSurface);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.on ? '断开连接' : (widget.busy ? '正在连接' : '连接'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: enabled
            ? () {
                MeowHaptics.toggle();
                widget.onTap();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed && !_reduce ? 0.94 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 连上时外扩的同形描边
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _ripple,
                      builder: (_, _) {
                        final t = const Cubic(0.2, 0.8, 0.3, 1).transform(_ripple.value);
                        final opacity = 0.8 * (1 - _ripple.value);
                        if (opacity <= 0.01) return const SizedBox.shrink();
                        return Transform.scale(
                          scale: 1 + 0.5 * t,
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              shape: shape.copyWith(side: BorderSide(color: active.withValues(alpha: opacity), width: 2)),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                // 本体：反色底 + 樱粉液面 + 图标；连上时同色投影，没连时淡淡的黑影
                Positioned.fill(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: ShapeDecoration(
                      shape: shape,
                      shadows: [
                        BoxShadow(
                          color: widget.on
                              ? active.withValues(alpha: 0.45)
                              : Colors.black.withValues(alpha: enabled ? 0.18 : 0),
                          blurRadius: size * 0.25,
                          offset: Offset(0, size * 0.1),
                        ),
                      ],
                    ),
                    child: ClipPath(
                      clipper: ShapeBorderClipper(shape: shape),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(color: idleFill),
                          if (enabled)
                            AnimatedBuilder(
                              animation: _level,
                              // 纵向缩放锚在底边（只改变换，不重新排版）
                              builder: (_, child) => Transform(
                                alignment: Alignment.bottomCenter,
                                transform: Matrix4.diagonal3Values(1, _level.value.clamp(0.0, 1.0), 1),
                                child: child,
                              ),
                              child: ColoredBox(color: active),
                            ),
                          Center(
                            child: TweenAnimationBuilder<Color?>(
                              tween: ColorTween(end: iconColor),
                              duration: const Duration(milliseconds: 220),
                              builder: (_, c, _) => Icon(Icons.power_settings_new_rounded, size: size * 0.42, color: c),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
