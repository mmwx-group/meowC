import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'button_fill.dart';
import 'glass.dart';
import 'motion.dart';
import 'svg_path.dart';
import 'tokens.dart';

/// 设计稿里的线性图标（24 网格、1.9 描边、圆头圆角）。Material 图标集里没有同形的，按稿子的路径画。
enum MeowGlyph {
  home('M4 11l8-7 8 7v8a1 1 0 0 1-1 1h-4v-6h-6v6H5a1 1 0 0 1-1-1z'),
  nodes(
    'M6 9.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5M18 3.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5'
    'M18 15.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5M8.2 10.8l7.6-3.6M8.2 13.2l7.6 3.6',
  ),
  activity('M3 12h4l3-8 4 16 3-8h4'),
  me('M12 4a4 4 0 1 0 0 8 4 4 0 0 0 0-8M4 21a8 8 0 0 1 16 0'),
  power('M12 3v9M6.3 6.3a8 8 0 1 0 11.4 0'),
  chevron('M9 6l6 6-6 6'),
  updown('M8 9l4-4 4 4M8 15l4 4 4-4'),
  refresh('M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5'),
  sliders('M4 7h10M18 7h2M4 17h2M10 17h10M16 5a2 2 0 1 0 0 4 2 2 0 0 0 0-4M8 15a2 2 0 1 0 0 4 2 2 0 0 0 0-4'),
  apps('M6 4h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2M15 4h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2h-3a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2'
      'M6 13h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2M14 17l2 2 4-4'),
  search('M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14M20 20l-3.5-3.5'),
  close('M6 6l12 12M18 6L6 18'),
  back('M15 6l-6 6 6 6'),
  up('M12 19V5M6 11l6-6 6 6'),
  down('M12 5v14M6 13l6 6 6-6');

  const MeowGlyph(this.d);
  final String d;
}

class MeowIcon extends StatelessWidget {
  const MeowIcon(MeowGlyph this.glyph, {super.key, double this.size = 22, this.color, this.stroke = 1.9}) : _d = null;

  /// 尺寸和颜色都跟外层 [IconTheme] 走（放进液态玻璃底栏这类由容器给图标定色定大小的地方）。
  const MeowIcon.themed(MeowGlyph this.glyph, {super.key, this.stroke = 1.9}) : size = null, color = null, _d = null;

  /// 直接给路径（24 网格的 SVG path `d`）：个别页面自己的图标，不进 [MeowGlyph]。
  const MeowIcon.path(String d, {super.key, double this.size = 22, this.color, this.stroke = 1.9}) : glyph = null, _d = d;

  final MeowGlyph? glyph;
  final String? _d;
  final double? size;
  final Color? color;
  final double stroke;

  /// 路径只解析一次（按 `d` 字符串）；描边粗细和颜色是画的时候才给的，不进这张表。
  static final _paths = <String, Path>{};

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final c = color ?? theme.color ?? context.mm.t1;
    final size = this.size ?? theme.size ?? 22;
    final d = glyph?.d ?? _d!;
    // 直接把路径画到画布上、颜色进画笔。以前是 SvgPicture.string + colorFilter：每个图标每次光栅化都要开一个离屏层，
    // 每种图标第一次出现还要起一个 isolate 解析 SVG、晚一两帧才出图。
    // 外面这层语义是 flutter_svg 原来就带的（标成图片、没有文字），留着，读屏听到的不变。
    return Semantics(
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(_paths[d] ??= parseSvgPath(d), c, stroke),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.path, this.color, this.stroke);

  final Path path;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    // 和 SVG 的摆法一样：24 网格等比缩进盒子、居中；描边粗细是网格里的数，跟着图标一起缩放。
    // 路径连描边都在 24 网格以内，不再另外裁一刀
    final scale = size.shortestSide / 24;
    canvas
      ..save()
      ..translate((size.width - 24 * scale) / 2, (size.height - 24 * scale) / 2)
      ..scale(scale)
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.path != path || old.color != color || old.stroke != stroke;
}

/// 分段选择：卡片底胶囊里放等宽分段，选中 = 墨色滑块配页面底色的字。
/// [onCard] = 放在白卡片上时槽用次级底（放在主卡 / 页面底上时槽用卡片底）。
/// 换段时滑块用弹跳弹簧滑过去（只平移、不拉伸，越过两端的部分被槽的圆角裁掉），段内文字颜色 220ms 交叉渐变。
/// [track] 换槽的颜色（主卡上的半透明白）；[glass] = 液态玻璃主题下滑块换成一块玻璃透镜、选中的字用墨色（经典主题照旧是墨色实心块）。
/// 液态玻璃主题下其余的滑块（没要玻璃的、低端机上画不了玻璃的）也不是墨色实心块：选中态那档静态半透明 + 细亮边、强调色的字（[MeowButtonFill.selected]）。
class MeowSegment<T> extends StatefulWidget {
  const MeowSegment({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.height = 44,
    this.onCard = false,
    this.fontSize = 14,
    this.track,
    this.glass = false,
  });

  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;
  final bool onCard;
  final double fontSize;
  final Color? track;
  final bool glass;

  @override
  State<MeowSegment<T>> createState() => _MeowSegmentState<T>();
}

class _MeowSegmentState<T> extends State<MeowSegment<T>> with SingleTickerProviderStateMixin {
  int get _index => widget.items.indexWhere((it) => it.$1 == widget.value);

  /// 滑块所在的段（小数 = 正在两段之间）；[_target] 是它要去的段
  late int _target = math.max(0, _index);
  late final _pos = AnimationController.unbounded(vsync: this, value: _target.toDouble());

  @override
  void didUpdateWidget(MeowSegment<T> old) {
    super.didUpdateWidget(old);
    final i = _index;
    if (i >= 0 && i != _target) {
      _target = i;
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
    final mm = context.mm;
    final height = widget.height;
    final outer = height >= 40 ? 14.0 : 11.0;
    final index = _index;
    final glass = widget.glass && meowGlassOn(context);
    final track = widget.track ?? (widget.onCard ? mm.card2 : mm.elev);
    final row = Row(
      children: [
        for (final (i, it) in widget.items.indexed) ...[
          if (i > 0) const SizedBox(width: _segGap),
          Expanded(
            child: Semantics(
              button: true,
              selected: i == index,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onChanged(it.$1),
                child: Container(
                  constraints: BoxConstraints(minHeight: height - _segGap * 2),
                  alignment: Alignment.center,
                  child: AnimatedDefaultTextStyle(
                    duration: MeowMotion.of(context, MeowMotion.colorFade),
                    style: TextStyle(
                      fontSize: widget.fontSize,
                      fontWeight: i == index ? FontWeight.w600 : FontWeight.w500,
                      // 玻璃滑块是透明的，选中的字仍用墨色
                      color: i == index ? (glass ? mm.t1 : mm.onSelected) : mm.t2,
                    ),
                    child: Text(it.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
    if (glass) {
      // 玻璃滑块画在文字下面、读它背后的槽与主卡；越过两端的部分由槽的圆角裁掉（只裁不离屏）
      return Container(
        constraints: BoxConstraints(minHeight: height),
        padding: const EdgeInsets.all(_segGap),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(outer)),
        child: Stack(
          children: [
            if (index >= 0)
              Positioned.fill(child: _GlassThumb(pos: _pos, count: widget.items.length, radius: outer - _segGap)),
            row,
          ],
        ),
      );
    }
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.all(_segGap),
      decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(outer)),
      // 滑块每帧重绘：自成一层，不连带整页重画
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _SegmentThumb(
            pos: _pos,
            count: widget.items.length,
            visible: index >= 0,
            color: mm.buttonFill(MeowButtonFill.selected),
            stroke: mm.glass ? mm.buttonSide : null,
            radius: outer - _segGap,
            slotRadius: outer,
          ),
          child: row,
        ),
      ),
    );
  }
}

/// 液态玻璃主题下分段的滑块：一块玻璃透镜，跟着 [pos] 平移（弹簧越过两端时伸进槽的内边距）。
class _GlassThumb extends StatelessWidget {
  const _GlassThumb({required this.pos, required this.count, required this.radius});

  final Animation<double> pos;
  final int count;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final glass = MeowGlassBox(
      style: MeowGlassStyles.lens(context),
      radius: BorderRadius.circular(radius),
      shadows: MeowGlassMetrics.lensShadow,
    );
    return LayoutBuilder(
      builder: (_, c) {
        final w = (c.maxWidth - _segGap * (count - 1)) / count;
        return AnimatedBuilder(
          animation: pos,
          child: glass,
          builder: (_, child) => Stack(
            clipBehavior: Clip.none,
            children: [Positioned(left: pos.value * (w + _segGap), top: 0, bottom: 0, width: w, child: child!)],
          ),
        );
      },
    );
  }
}

const _segGap = 3.0;

/// 分段的滑块：画在分段行的背后，位置跟着 [pos] 只重绘、不重排。
class _SegmentThumb extends CustomPainter {
  _SegmentThumb({
    required this.pos,
    required this.count,
    required this.visible,
    required this.color,
    required this.radius,
    required this.slotRadius,
    this.stroke,
  }) : super(repaint: pos);

  final Animation<double> pos;
  final int count;
  final bool visible;
  final Color color;
  final double radius, slotRadius;

  /// 液态玻璃主题下滑块的细亮边（[MeowButtonColors.buttonSide]）；经典 = null
  final BorderSide? stroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible || count <= 0) return;
    final w = (size.width - _segGap * (count - 1)) / count;
    final x = pos.value * (w + _segGap);
    final thumb = RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, w, size.height), Radius.circular(radius));
    // 弹簧越过两端时滑块伸进槽的内边距，再往外就被槽的圆角裁掉
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius((Offset.zero & size).inflate(_segGap), Radius.circular(slotRadius)))
      ..drawRRect(thumb, Paint()..color = color);
    final s = stroke;
    if (s != null) {
      // 描在滑块里面（同 BoxDecoration 的边框）
      canvas.drawRRect(thumb.deflate(s.width / 2), s.toPaint());
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SegmentThumb old) =>
      old.pos != pos ||
      old.count != count ||
      old.visible != visible ||
      old.color != color ||
      old.stroke != stroke ||
      old.radius != radius ||
      old.slotRadius != slotRadius;
}

/// 电源键（圆角方块）：墨色底，「液面」是一层从底边纵向缩放的樱粉色块，只走变换不触发布局，进度本身就是液面、不再叠转圈。
/// - 连接中（[busy]）：液面 1.2s 先快后慢注到七成，之后 6s 线性涨到 0.92（久连不上也不会注满）；
/// - 连上（[on]）：弹簧补满，同时一圈樱粉描边外扩一次（涟漪），图标从 0.6 弹回 1、颜色渐变成墨色；
/// - 断开 / 连接失败：350ms 排空。
/// 初值按出现时的状态给：切回首页时已连接就是满的，不重放。不可用 = 半透明。
/// 液态玻璃主题：没有墨色实心底（用户 2026-10-28 要求按钮别再是纯色，同 iOS），液面半透明（55%）地在里面涨、图标用墨色；
/// 液面之上盖一块几乎不着色的玻璃（樱粉着色那一档的边缘折射与高光），形状仍是圆角方块、不加光晕（用户明确不要正圆和光晕），
/// 只留一层很淡的投影。低端机画不了玻璃时底换成按钮那档静态半透明 + 细亮边（[MeowButtonFill.plain]），照样不是实心块。
class MeowPowerButton extends StatefulWidget {
  const MeowPowerButton({
    super.key,
    required this.on,
    required this.onTap,
    this.enabled = true,
    this.busy = false,
    this.size = 80,
  });

  final bool on, enabled, busy;
  final VoidCallback onTap;
  final double size;

  @override
  State<MeowPowerButton> createState() => _MeowPowerButtonState();
}

enum _PowerPhase { off, connecting, on }

class _MeowPowerButtonState extends State<MeowPowerButton> with TickerProviderStateMixin {
  late final _level = AnimationController.unbounded(vsync: this, value: widget.on ? 1 : 0);
  late final _ripple = AnimationController(vsync: this, duration: MeowMotion.ripple);
  late final _icon = AnimationController.unbounded(vsync: this, value: 1);
  bool _started = false;

  _PowerPhase _phaseOf(MeowPowerButton w) =>
      w.on ? _PowerPhase.on : (w.busy ? _PowerPhase.connecting : _PowerPhase.off);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 连接中切回来：接着注（从底开始，之前注到哪了不知道）
    if (!_started) {
      _started = true;
      if (_phaseOf(widget) == _PowerPhase.connecting) _apply(_PowerPhase.connecting);
    }
  }

  @override
  void didUpdateWidget(MeowPowerButton old) {
    super.didUpdateWidget(old);
    final next = _phaseOf(widget);
    if (next != _phaseOf(old)) _apply(next);
  }

  void _apply(_PowerPhase phase) {
    final reduce = MeowMotion.reduced(context);
    switch (phase) {
      case _PowerPhase.connecting:
        if (reduce) {
          _level.value = MeowMotion.pourFastLevel;
        } else {
          _level.animateWith(PourSimulation(_level.value));
        }
      case _PowerPhase.on:
        MeowMotion.spring(_level, 1, MeowMotion.bouncy, reduce: reduce);
        if (!reduce) {
          _ripple.forward(from: 0);
          _icon.value = MeowMotion.iconPopFrom;
          MeowMotion.spring(_icon, 1, MeowMotion.bouncy);
        }
      case _PowerPhase.off:
        if (reduce) {
          _level.value = 0;
        } else {
          _level.animateTo(0, duration: MeowMotion.drainDuration, curve: MeowMotion.drain);
        }
    }
  }

  @override
  void dispose() {
    _level.dispose();
    _ripple.dispose();
    _icon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final on = widget.on;
    final size = widget.size;
    final radius = BorderRadius.circular(size * 0.325);
    // 玻璃透镜画不画看宿主（低端机不画）；没有实心底 / 半透明液面 / 墨色图标看主题（低端机上也一样）
    final glass = meowGlassOn(context);
    final glassTheme = mm.glass;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: on ? '断开连接' : (widget.busy ? '正在连接' : '连接'),
      child: Opacity(
        opacity: widget.enabled || widget.busy ? 1 : 0.4,
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 底：阴影只换颜色、半径不变（玻璃下不要这圈光晕，投影由玻璃自己带）。
                // 液态玻璃主题没有实心底：有透镜时透镜读的就是背后的卡片；低端机没有透镜，垫一层静态半透明
                Positioned.fill(
                  child: glassTheme
                      ? (glass
                            ? const SizedBox.shrink()
                            : DecoratedBox(
                                decoration: BoxDecoration(color: mm.buttonFill(MeowButtonFill.plain), borderRadius: radius),
                              ))
                      : glass
                      ? DecoratedBox(decoration: BoxDecoration(color: mm.t1, borderRadius: radius))
                      : AnimatedContainer(
                          duration: MeowMotion.of(context, MeowMotion.colorFade),
                          decoration: BoxDecoration(
                            color: mm.t1,
                            borderRadius: radius,
                            boxShadow: [
                              BoxShadow(
                                color: on ? mm.pink.withValues(alpha: 0.5) : const Color(0x382A2130),
                                blurRadius: size * 0.25,
                                offset: Offset(0, size * 0.1),
                              ),
                            ],
                          ),
                        ),
                ),
                // 液面：弹簧补满时会越过 1，越出的部分被圆角裁掉
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: radius,
                    child: AnimatedBuilder(
                      animation: _level,
                      builder: (_, child) => Transform(
                        alignment: Alignment.bottomCenter,
                        transform: Matrix4.diagonal3Values(1, _level.value.clamp(0.0, 1.5), 1),
                        child: child,
                      ),
                      // 液态玻璃主题：液面半透明（直接用带透明度的颜色，不套 Opacity 层）
                      child: ColoredBox(color: glassTheme ? mm.btnOn.withValues(alpha: mm.btnOn.a * 0.55) : mm.btnOn),
                    ),
                  ),
                ),
                // 玻璃：画在底与液面之后，读的就是它们（边缘把液面弯进来）
                if (glass)
                  Positioned.fill(
                    child: MeowGlassBox(
                      style: MeowGlassStyles.power(context),
                      radius: radius,
                      shadows: MeowGlassMetrics.powerShadow,
                    ),
                  )
                // 低端机：细亮边描在液面上面（同其它按钮）
                else if (glassTheme)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(decoration: BoxDecoration(border: mm.buttonBorder, borderRadius: radius)),
                    ),
                  ),
                // 涟漪：连上那一下外扩一圈，平时不画
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _ripple,
                      builder: (_, child) {
                        final v = _ripple.value;
                        if (v <= 0 || v >= 1) return const SizedBox.shrink();
                        final t = MeowMotion.emphasized.transform(v);
                        return Opacity(
                          opacity: 0.8 * (1 - t),
                          child: Transform.scale(scale: 1 + 0.5 * t, child: child),
                        );
                      },
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          border: Border.all(color: mm.btnOn, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: ScaleTransition(
                    scale: _icon,
                    child: TweenAnimationBuilder<Color?>(
                      // 液态玻璃主题下没有墨色底，连没连上图标都是墨色
                      tween: ColorTween(end: glassTheme ? mm.t1 : (on ? mm.onBtn : mm.bg)),
                      duration: MeowMotion.of(context, MeowMotion.colorFade),
                      builder: (_, c, _) => MeowIcon(MeowGlyph.power, size: size * 0.43, color: c, stroke: 2.2),
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

/// 地区码小标签（HK / JP …）：只用于出口 IP 查到的归属地代码。节点名里的国旗原样显示（和代理组名一个画法），不再换成这个标签。
/// [large] = 34×24 的大号。
class RegionTag extends StatelessWidget {
  const RegionTag(this.code, {super.key, this.large = false});
  final String code;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final text = Text(
      code,
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
      style: TextStyle(fontSize: large ? 11 : 10, fontWeight: FontWeight.w700, color: mm.t2, height: 1.2),
    );
    if (large) {
      return Container(
        constraints: const BoxConstraints(minWidth: 34, minHeight: 24),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(7)),
        child: text,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(5)),
      child: text,
    );
  }
}

/// 行首的图标方块：柔粉底 + 玫红图标（[tint] 可换色，底取它的 14%）。
class IconTile extends StatelessWidget {
  const IconTile({super.key, this.icon, this.glyph, this.size = 32, this.tint});
  final IconData? icon;
  final MeowGlyph? glyph;
  final double size;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final fg = tint ?? mm.accent;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint == null ? mm.soft : fg.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.31),
      ),
      child: glyph != null ? MeowIcon(glyph!, size: size * 0.53, color: fg) : Icon(icon, size: size * 0.56, color: fg),
    );
  }
}

/// 小按钮的底：40×30 奶白胶囊（同延迟胶囊一族，底色 card2），里面放 13–14 号的图标。
/// 节点页组卡的测速 / 展开钮、设置行末尾的箭头都用它（以前是裸的小图标，iOS 上用户反馈太小不好点）。
/// [onTap] 为 null = 只是个底（整行的点按照旧由行自己接）。
class MeowChip extends StatelessWidget {
  const MeowChip({super.key, required this.child, this.onTap, this.tooltip});

  static const width = 40.0, height = 30.0;

  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final body = Material(
      color: context.mm.card2,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(width: width, height: height, child: Center(child: child)),
      ),
    );
    return tooltip == null ? body : Tooltip(message: tooltip, child: body);
  }
}

/// 胶囊里的箭头（设置行行尾、节点页组卡的展开钮共用），对齐 iOS 的 13pt 中粗 `chevron.right`：约 8dp 高、2dp 粗。
/// 箭头路径在 24 网格里只占 12 格高、描边也跟着缩放——以前直接用 14 号的 [MeowIcon]，画出来 7dp 高、1.1dp 粗，
/// 用户对照 iOS 说「箭头按钮要和 iOS 保持一致」。
class MeowChipChevron extends StatelessWidget {
  const MeowChipChevron({super.key, this.color});
  final Color? color;

  static const size = 16.0, stroke = 3.0;

  @override
  Widget build(BuildContext context) =>
      MeowIcon(MeowGlyph.chevron, size: size, stroke: stroke, color: color ?? context.mm.t2);
}

/// 状态小圆点 + 文案。
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// 品牌头像（浅 / 深两张，随主题切）。
class BrandHead extends StatelessWidget {
  const BrandHead({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.31),
      // 256 的小图（scripts/make-brand-assets.py 从 1024 的那张缩好的）：整张 1024 解码后 4MB 多，这里最大只画 60dp。
      // 不用 cacheWidth 让引擎现缩——那是不带 mipmap 的双线性，缩这么多倍会出锯齿。
      child: Image.asset(
        dark ? 'assets/images/icon_256.png' : 'assets/images/icon_light_256.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}

/// 圆角字体族：标题 / 大数字用（系统没有圆体时回落到默认字体）。
const meowRounded = <String>['Google Sans', 'Segoe UI Variable Display', 'Segoe UI', 'Microsoft YaHei UI', 'Noto Sans SC'];
