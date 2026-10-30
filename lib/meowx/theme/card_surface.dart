import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'backdrop.dart';
import 'tokens.dart';

/// 内容卡片的底（网速卡、订阅卡、指标格、出口 IP、各页列表卡……）。
///
/// 经典主题：就是原来那份实色 [BoxDecoration]（一个像素不变）。
/// 液态玻璃主题：磨砂玻璃卡片 [MeowFrostBox]（[MeowCard] / [MeowCardMaterial] / GlassCard 都用它）。这里的 [card] decoration
/// 只剩一个地方用（DecoratedSliver 包的整张列表卡，拿不到自己在屏幕上的位置）：退回半透明白 + 亮边的「静态玻璃」。
/// 不挂实时模糊（BackdropFilter）：安卓上逐卡模糊是以前卡顿的原因。
extension MeowCardSurface on MeowTokens {
  /// 卡片的 decoration：[color] 缺省 = 卡片底 [MeowTokens.elev]（选中态等传别的颜色，玻璃主题下照样带亮边与高光）。
  /// [openTop] / [openBottom]：这一块是一张卡片中间的一截（懒加载列表一行一块拼成一张卡），这一侧接着别的块，
  /// 玻璃主题下不画这一侧的亮边、高光与投影（经典主题下没有区别）。
  Decoration card(BorderRadiusGeometry radius, {Color? color, bool openTop = false, bool openBottom = false}) {
    final rim = cardRim;
    if (rim == null) return BoxDecoration(color: color ?? elev, borderRadius: radius);
    return MeowCardDecoration(
      color: color ?? elev,
      borderRadius: radius,
      rim: rim,
      sheen: cardSheen,
      shadow: cardShadow,
      openTop: openTop,
      openBottom: openBottom,
    );
  }
}

/// 液态玻璃主题的内容卡片底，见 [MeowCardSurface]。
@immutable
class MeowCardDecoration extends Decoration {
  const MeowCardDecoration({
    required this.color,
    required this.borderRadius,
    required this.rim,
    required this.sheen,
    required this.shadow,
    this.openTop = false,
    this.openBottom = false,
  });

  final Color color;

  /// 这一侧接着同一张卡片的别的块（见 [MeowCardSurface.card]）
  final bool openTop, openBottom;
  final BorderRadiusGeometry borderRadius;

  /// 1px 亮边、顶边内高光、投影的颜色（投影透明 = 不画）
  final Color rim, sheen, shadow;

  /// 投影：模糊半径与下移量。只画在卡片外面（[BlurStyle.outer]），不会透进半透明的卡片底把它弄脏
  static const shadowBlur = 16.0, shadowDy = 2.0;

  /// 顶边内高光从顶上往下淡出的长度（不超过卡片高度的一半）
  static const sheenFade = 22.0;

  RRect rrect(Rect rect, TextDirection? textDirection) =>
      borderRadius.resolve(textDirection).toRRect(rect).scaleRadii();

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      rrect(Offset.zero & size, textDirection).contains(position);

  @override
  Path getClipPath(Rect rect, TextDirection textDirection) => Path()..addRRect(rrect(rect, textDirection));

  @override
  bool get isComplex => false;

  @override
  MeowCardDecoration? lerpFrom(Decoration? a, double t) => a is MeowCardDecoration ? _lerp(a, this, t) : null;

  @override
  MeowCardDecoration? lerpTo(Decoration? b, double t) => b is MeowCardDecoration ? _lerp(this, b, t) : null;

  static MeowCardDecoration _lerp(MeowCardDecoration a, MeowCardDecoration b, double t) => MeowCardDecoration(
    color: Color.lerp(a.color, b.color, t)!,
    borderRadius: BorderRadiusGeometry.lerp(a.borderRadius, b.borderRadius, t)!,
    rim: Color.lerp(a.rim, b.rim, t)!,
    sheen: Color.lerp(a.sheen, b.sheen, t)!,
    shadow: Color.lerp(a.shadow, b.shadow, t)!,
    openTop: t < 0.5 ? a.openTop : b.openTop,
    openBottom: t < 0.5 ? a.openBottom : b.openBottom,
  );

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _MeowCardPainter(this);

  @override
  bool operator ==(Object other) =>
      other is MeowCardDecoration &&
      other.color == color &&
      other.borderRadius == borderRadius &&
      other.rim == rim &&
      other.sheen == sheen &&
      other.shadow == shadow &&
      other.openTop == openTop &&
      other.openBottom == openBottom;

  @override
  int get hashCode => Object.hash(color, borderRadius, rim, sheen, shadow, openTop, openBottom);
}

class _MeowCardPainter extends BoxPainter {
  _MeowCardPainter(this.d);

  final MeowCardDecoration d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    final rrect = d.rrect(rect, configuration.textDirection);
    final open = d.openTop || d.openBottom;
    // 中间的一截：亮边与投影按往开口那侧延长出去的形状画，再裁回这一块（左右留出投影的位置），开口那侧就没有线
    const reach = MeowCardDecoration.shadowBlur + MeowCardDecoration.shadowDy + 2;
    final edge = open
        ? RRect.fromRectAndCorners(
            Rect.fromLTRB(rect.left, rect.top - (d.openTop ? reach : 0), rect.right, rect.bottom + (d.openBottom ? reach : 0)),
            topLeft: rrect.tlRadius,
            topRight: rrect.trRadius,
            bottomLeft: rrect.blRadius,
            bottomRight: rrect.brRadius,
          )
        : rrect;
    if (open) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(
        rect.left - reach,
        d.openTop ? rect.top : rect.top - reach,
        rect.right + reach,
        d.openBottom ? rect.bottom : rect.bottom + reach,
      ));
    }
    if (d.shadow.a > 0) {
      canvas.drawRRect(
        edge.shift(const Offset(0, MeowCardDecoration.shadowDy)),
        Paint()
          ..color = d.shadow
          ..maskFilter = MaskFilter.blur(BlurStyle.outer, Shadow.convertRadiusToSigma(MeowCardDecoration.shadowBlur / 2)),
      );
    }
    canvas.drawRRect(rrect, Paint()..color = d.color);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // 亮边画在卡片里面半像素（整条线都在卡片内，不和外面的投影叠）
    canvas.drawRRect(edge.deflate(0.5), stroke..color = d.rim);
    // 顶边内高光：亮边里面再一圈，只在顶上亮、往下很快淡掉（圆角处顺着弧线淡出）
    if (!d.openTop) {
      final fade = math.min(MeowCardDecoration.sheenFade, size.height / 2);
      canvas.drawRRect(
        edge.deflate(1.5),
        stroke
          ..color = const Color(0xFFFFFFFF)
          ..shader = ui.Gradient.linear(rect.topLeft, rect.topLeft + Offset(0, fade), [d.sheen, d.sheen.withValues(alpha: 0)]),
      );
    }
    if (open) canvas.restore();
  }
}

/// 卡片形状的 [Material]（点按水波、形状描边由它画）：经典主题原样是 `Material(color: …)`；
/// 液态玻璃主题下底由 [MeowFrostBox] 画（磨砂玻璃），[Material] 本身透明、只管水波与裁剪。
class MeowCardMaterial extends StatelessWidget {
  const MeowCardMaterial({
    super.key,
    this.color,
    this.borderRadius,
    this.shape,
    this.clipBehavior = Clip.none,
    required this.child,
  }) : assert(borderRadius == null || shape == null);

  /// 缺省 = 卡片底 [MeowTokens.elev]
  final Color? color;
  final BorderRadiusGeometry? borderRadius;

  /// [RoundedRectangleBorder]（可带描边，如选中态）/ [StadiumBorder]
  final ShapeBorder? shape;
  final Clip clipBehavior;
  final Widget child;

  BorderRadiusGeometry get _radius => switch (shape) {
    RoundedRectangleBorder(:final borderRadius) => borderRadius,
    StadiumBorder() => const BorderRadius.all(Radius.circular(1e4)),
    _ => borderRadius ?? BorderRadius.zero,
  };

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    if (mm.cardRim == null) {
      return Material(
        color: color ?? mm.elev,
        borderRadius: borderRadius,
        shape: shape,
        clipBehavior: clipBehavior,
        child: child,
      );
    }
    return MeowFrostBox(
      radius: _radius,
      tint: color,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: borderRadius,
        shape: shape,
        clipBehavior: clipBehavior,
        child: child,
      ),
    );
  }
}


/// 内容卡片：经典主题就是原来的 `Container(decoration: BoxDecoration(color, borderRadius))`；液态玻璃主题是磨砂玻璃 [MeowFrostBox]。
/// [color] 缺省 = 卡片底；[openTop] / [openBottom] 同 [MeowCardSurface.card]（一张卡片中间的一截）。
class MeowCard extends StatelessWidget {
  const MeowCard({
    super.key,
    required this.radius,
    this.color,
    this.openTop = false,
    this.openBottom = false,
    this.padding,
    this.width,
    this.constraints,
    this.clipBehavior = Clip.none,
    this.child,
  });

  final BorderRadiusGeometry radius;
  final Color? color;
  final bool openTop, openBottom;
  final double? width;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;
  final Clip clipBehavior;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    if (mm.backdrop == null) {
      return Container(
        width: width,
        padding: padding,
        constraints: constraints,
        clipBehavior: clipBehavior,
        decoration: BoxDecoration(color: color ?? mm.elev, borderRadius: radius),
        child: child,
      );
    }
    Widget body = Container(width: width, padding: padding, constraints: constraints, child: child);
    if (clipBehavior != Clip.none) body = ClipRRect(borderRadius: radius, clipBehavior: clipBehavior, child: body);
    return MeowFrostBox(radius: radius, tint: color, openTop: openTop, openBottom: openBottom, child: body);
  }
}

/// 磨砂玻璃卡片的底（画在子树下面）：投影 → 卡片背后那块预模糊背景（按卡片此刻在屏幕上的位置裁 [MeowBackdropImages.frost]）
/// → 对比度垫层（叠在预模糊图里、按位置算，见 [MeowScrimMap]；图还没好时整套卡片统一，见 [MeowBackdrop.scrim]）→ 白色填充（自上而下两档；[tint] 换成这个颜色，如选中态）
/// → 顶部 1dp 内高光、底部 1dp 内暗边 → 顶部反光 → 140° 渐变高光边。参数见 [MeowFrostStyle]，与底栏同一套。
///
/// 不逐帧实时模糊：背景是静止的，预模糊图只在换设置 / 改尺寸时重新渲染（../app/backdrop_host.dart）。卡片在屏幕上挪了位置时自己重画：
/// 滚动时由宿主统一叫醒（[markAllMoved]），切 Tab 平推与页面转场由 [MeowFrostFollow] 在动画推进的那一刻叫醒（和位移同一帧画），
/// 其它情况（展开等）每帧画完后核对一次位置，变了就下一帧重画。预模糊图还没渲染好时先按底色渐层画。
///
/// 卡片自己是一层（repaint boundary），内容再单独一层：挪位置时只重录卡片底这一小张，不连带整页 / 整个列表项重录
/// （2026-10 安卓用户反馈液态玻璃下动画卡：以前每张卡片挪一下，它所在的整页都要重新录一遍，而且只能晚一帧、隔一帧画）。
class MeowFrostBox extends SingleChildRenderObjectWidget {
  MeowFrostBox({
    super.key,
    required this.radius,
    this.tint,
    this.openTop = false,
    this.openBottom = false,
    this.enabled = true,
    Widget? child,
  }) : super(child: child == null ? null : RepaintBoundary(child: child));

  final BorderRadiusGeometry radius;
  final Color? tint;
  final bool openTop, openBottom;

  /// false = 这一刻不画玻璃（如连接主卡连上后换成实色渐变；留着这一层，切换时子树不重建）
  final bool enabled;

  /// 让屏幕上的玻璃卡片按新位置重画（滚动、平推、转场时；在位移生效的那一帧画之前叫，当帧就画对）。
  /// 不在屏幕上的（隐藏的 Tab 页、列表缓存区里的）跳过，轮到它们露面时自然会画
  static void markAllMoved() {
    for (final box in _RenderMeowFrostBox._live) {
      if (box._onScreen) box.markNeedsPaint();
    }
  }

  /// 测试用：玻璃卡片的底一共画了几次
  @visibleForTesting
  static int get debugPaintCount => _RenderMeowFrostBox._paints;

  /// 测试用：按卡片实际走的那条路画一张卡片 [card] 的投影
  @visibleForTesting
  static void debugPaintShadow(Canvas canvas, RRect card, Color color, double dpr) =>
      _FrostShadow.paint(canvas, card, color, dpr);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeowFrostBox(_config(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderMeowFrostBox).config = _config(context);

  _FrostConfig _config(BuildContext context) {
    final mm = context.mm;
    return _FrostConfig(
      spec: enabled ? mm.backdrop : null,
      images: MeowBackdropScope.of(context),
      radius: radius.resolve(Directionality.maybeOf(context) ?? TextDirection.ltr),
      tint: tint,
      openTop: openTop,
      openBottom: openBottom,
      scrim: mm.backdropScrim,
      fallback: mm.bgGradient ?? [mm.bg, mm.bg],
      screen: MediaQuery.sizeOf(context),
      dpr: MediaQuery.devicePixelRatioOf(context),
    );
  }
}

@immutable
class _FrostConfig {
  const _FrostConfig({
    required this.spec,
    required this.images,
    required this.radius,
    required this.tint,
    required this.openTop,
    required this.openBottom,
    required this.scrim,
    required this.fallback,
    required this.screen,
    required this.dpr,
  });

  final MeowBackdrop? spec;
  final MeowBackdropImages? images;
  final BorderRadius radius;
  final Color? tint;
  final bool openTop, openBottom;
  final double scrim;
  final List<Color> fallback;
  final Size screen;
  final double dpr;

  @override
  bool operator ==(Object other) =>
      other is _FrostConfig &&
      other.spec == spec &&
      identical(other.images, images) &&
      other.radius == radius &&
      other.tint == tint &&
      other.openTop == openTop &&
      other.openBottom == openBottom &&
      other.screen == screen &&
      other.dpr == dpr &&
      other.scrim == scrim &&
      other.fallback.length == fallback.length &&
      Iterable.generate(fallback.length).every((i) => other.fallback[i] == fallback[i]);

  @override
  int get hashCode => Object.hash(spec, images, radius, tint, openTop, openBottom, screen);
}

class _RenderMeowFrostBox extends RenderProxyBox {
  _RenderMeowFrostBox(this._config);

  static final _live = <_RenderMeowFrostBox>{};
  static bool _checking = false;
  static int _paints = 0;

  /// 每帧画完后核对一次：卡片在屏幕上的位置变了（展开等把它挪走了，又没有人叫醒它）就下一帧重画。
  /// 只看屏幕上的：隐藏页里的卡片以前在这里每帧都被标一次、却永远不画
  static void _ensureFrameCheck() {
    if (_checking) return;
    _checking = true;
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      for (final box in _live) {
        if (!box._onScreen || !box.hasSize || box._painted == null) continue;
        final now = box.localToGlobal(Offset.zero);
        if ((now - box._painted!).distanceSquared > 0.25) box.markNeedsPaint();
      }
    });
  }

  /// 自己是一层：挪位置时只重录这一层（卡片底），内容在下面单独一层（见 [MeowFrostBox] 的构造）
  @override
  bool get isRepaintBoundary => true;

  /// 这一层此刻在画面的图层树里（隐藏的 Tab 页、没画过的为 false）
  bool get _onScreen => attached && (layer?.attached ?? false);

  _FrostConfig _config;
  set config(_FrostConfig v) {
    if (v == _config) return;
    _config = v;
    markNeedsPaint();
  }

  /// 上一次画的时候卡片左上角在屏幕上的位置
  Offset? _painted;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _live.add(this);
    _ensureFrameCheck();
  }

  @override
  void detach() {
    _live.remove(this);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return super.paint(context, offset);
    final c = _config;
    final spec = c.spec;
    if (spec == null) return super.paint(context, offset);
    final origin = localToGlobal(Offset.zero);
    _painted = origin;
    _paints++;
    final canvas = context.canvas;
    final dark = spec.dark;
    final rect = offset & size;
    final rrect = c.radius.toRRect(rect).scaleRadii();
    final open = c.openTop || c.openBottom;
    // 一张卡片中间的一截：高光边与投影按往开口那侧延长出去的形状画，再裁回这一块
    const reach = MeowFrostStyle.dropBlur + MeowFrostStyle.dropDy + 4;
    final edge = open
        ? RRect.fromRectAndCorners(
            Rect.fromLTRB(rect.left, rect.top - (c.openTop ? reach : 0), rect.right, rect.bottom + (c.openBottom ? reach : 0)),
            topLeft: rrect.tlRadius,
            topRight: rrect.trRadius,
            bottomLeft: rrect.blRadius,
            bottomRight: rrect.brRadius,
          )
        : rrect;
    if (open) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(
        rect.left - reach,
        c.openTop ? rect.top : rect.top - reach,
        rect.right + reach,
        c.openBottom ? rect.bottom : rect.bottom + reach,
      ));
    }

    // 投影（卡片底是不透明的背景图，盖得住投影落在卡片下面的那部分）。四角圆角一样时用全 App 共用的九宫格图
    // （[_FrostShadow]）：以前每张卡片每次重画都现算两次高斯模糊，滚动、平推时每帧都在算
    final aurora = spec.aurora;
    final drop = MeowFrostStyle.drop(dark, spec.hueA, aurora: aurora);
    _FrostShadow.paint(canvas, edge, drop, c.dpr);

    // 卡片背后那块背景：预模糊图按屏幕坐标贴成着色器、直接画成这个圆角形状（不先按圆角裁切：裁切在 Impeller 下要多走模板缓冲）
    final images = c.images;
    final fill = spec.fill;
    // 换设置后新图渲染完之前（防抖 + 渲染，一两百毫秒）先用旧图
    if (images != null) {
      // 图上的像素 p 在屏幕上是 p / k，屏幕点 g 在这块画布上是 g − origin + offset
      final k = images.frostScale;
      final dx = offset.dx - origin.dx, dy = offset.dy - origin.dy;
      final matrix = Float64List.fromList([1 / k, 0, 0, 0, 0, 1 / k, 0, 0, 0, 0, 1, 0, dx, dy, 0, 1]);
      canvas.drawRRect(
        rrect,
        Paint()..shader = ImageShader(images.frost, TileMode.clamp, TileMode.clamp, matrix, filterQuality: FilterQuality.low),
      );
    } else {
      // 预模糊图还没好：先按底色渐层（屏幕坐标）画
      final screen = c.screen;
      final start = rect.topLeft - origin;
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = ui.Gradient.linear(
            start,
            spec.diagonal ? start + Offset(screen.width, screen.height) : start + Offset(0, screen.height),
            c.fallback,
          ),
      );
    }
    // 对比度垫层：模糊图里已经叠了按位置算的局部垫层（MeowScrimMap）就不再画；图还没好时用整套卡片统一的值
    // （见 MeowBackdrop.scrim）。选中态等自带不透明底色的不垫
    final tint = c.tint;
    if (tint == null && c.scrim > 0 && !(images?.localScrim ?? false)) {
      canvas.drawRRect(rrect, Paint()..color = (dark ? Colors.black : Colors.white).withValues(alpha: c.scrim));
    }
    canvas.drawRRect(
      rrect,
      tint != null
          ? (Paint()..color = tint)
          : (Paint()
              ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
                Colors.white.withValues(alpha: fill.top),
                Colors.white.withValues(alpha: fill.bottom),
              ])),
    );
    // 左上角的斜向高光（主控同款）：135° 方向，沿该方向 sheenLength 处淡完；只在卡片顶上那一截画
    final sheen = MeowFrostStyle.sheen(dark, aurora: aurora);
    if (sheen != null && !c.openTop) {
      const d = MeowFrostStyle.sheenLength / math.sqrt2;
      canvas.drawRRect(
        rrect,
        Paint()..shader = ui.Gradient.linear(rect.topLeft, rect.topLeft + const Offset(d, d), [sheen, sheen.withValues(alpha: 0)]),
      );
    }

    // 顶部 1dp 内高光、底部 1dp 内暗边：沿边线描一道，往里很快淡掉（圆角处顺着弧线）
    final band = math.max(rrect.tlRadius.y, 6.0);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (!c.openTop) {
      canvas.drawRRect(
        edge.deflate(0.5),
        line
          ..shader = ui.Gradient.linear(rect.topLeft, rect.topLeft + Offset(0, band), [
            MeowFrostStyle.spec(dark, aurora: aurora),
            MeowFrostStyle.spec(dark, aurora: aurora).withValues(alpha: 0),
          ]),
      );
    }
    if (!c.openBottom && !aurora) {
      final inner = MeowFrostStyle.inner(dark, spec.hueA);
      canvas.drawRRect(
        edge.deflate(0.5),
        line
          ..shader = ui.Gradient.linear(rect.bottomLeft, rect.bottomLeft - Offset(0, band), [
            inner,
            inner.withValues(alpha: 0),
          ]),
      );
    }
    // 140° 渐变高光边
    final dir = Offset(math.sin(140 * math.pi / 180), -math.cos(140 * math.pi / 180));
    final length = (size.width * dir.dx).abs() + (size.height * dir.dy).abs();
    final center = rect.center;
    canvas.drawRRect(
      edge.deflate(MeowFrostStyle.rimWidth / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = MeowFrostStyle.rimWidth
        ..shader = ui.Gradient.linear(
          center - dir * (length / 2),
          center + dir * (length / 2),
          MeowFrostStyle.rim(dark, aurora: aurora),
          MeowFrostStyle.rimStops,
        ),
    );
    if (open) canvas.restore();
    super.paint(context, offset);
  }
}

/// 玻璃卡片的投影图：按（圆角、颜色、像素比）画一张九宫格图、全 App 共用，每张卡片画的时候只贴图。
/// 图里是一张卡片连同四周的投影（与原来的两层一样：模糊 [MeowFrostStyle.dropBlur] 下移 [MeowFrostStyle.dropDy]
/// + 1dp 的贴边小影），中间一像素拉伸成卡片的长宽——直边上的模糊处处一样，拉伸出来与现算的一致。
/// 图里那张卡片的中心离每条边都要有 r + 三倍 sigma：卡片太小的话四边的模糊互相影响，中间那一像素到不了全浓度，
/// 拉伸出来整圈投影淡一成（最初按 2r+1 的小卡片画就是这样）。
/// 投影本来就是糊的，图最多按 1.5 倍像素画（一张二三百 KB，常用的圆角十来种）。
/// 九宫格四个角各要占「r + 三倍 sigma」再加外边，卡片的长或宽不到 2(r + 三倍 sigma) 时四个角会叠在一起、整张图被压扁，
/// 本该压在卡片下面的深色部分挤到卡片外面（小卡片、胶囊外面一大圈暗影，2026-10-29 用户在小米 14 上实报）——
/// 这种小卡片照原来现算两层模糊（[_paintDirect]），只有够大的卡片贴图。
abstract final class _FrostShadow {
  static final sigma = Shadow.convertRadiusToSigma(MeowFrostStyle.dropBlur / 2);

  /// 三倍 sigma（模糊伸出去 / 伸进来的距离）
  static final _spread = (3 * sigma).ceilToDouble();

  /// 卡片四周要留的边：三倍 sigma 加下移量
  static final margin = _spread + MeowFrostStyle.dropDy;

  static final _cache = <(double, int, double), ui.Image>{};

  static ui.Image _image(double r, Color color, double scale) {
    final key = (r, color.toARGB32(), scale);
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 24) {
      for (final image in _cache.values) {
        image.dispose();
      }
      _cache.clear();
    }
    final inner = 2 * (r + _spread) + 1;
    final side = inner + 2 * margin;
    final card = RRect.fromRectAndRadius(Rect.fromLTWH(margin, margin, inner, inner), Radius.circular(r));
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    canvas.drawRRect(
      card.shift(const Offset(0, MeowFrostStyle.dropDy)),
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
    canvas.drawRRect(
      card.shift(const Offset(0, 1)),
      Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
    );
    final picture = recorder.endRecording();
    final px = (side * scale).ceil();
    final image = picture.toImageSync(px, px);
    picture.dispose();
    return _cache[key] = image;
  }

  /// 在卡片 [card] 四周画投影：四角圆角一样、而且够大的贴九宫格图，其余现算
  static void paint(Canvas canvas, RRect card, Color color, double dpr) {
    if (color.a == 0) return;
    final r = card.tlRadiusX;
    final uniform = [card.tlRadiusY, card.trRadiusX, card.trRadiusY, card.blRadiusX, card.blRadiusY, card.brRadiusX, card.brRadiusY]
        .every((v) => (v - r).abs() < 0.01);
    final minSide = 2 * (r + _spread) + 1;
    if (uniform && card.width >= minSide && card.height >= minSide) {
      _paintNine(canvas, card.outerRect, r, color, dpr);
    } else {
      _paintDirect(canvas, card, color);
    }
  }

  /// 原来的画法：两层现算的模糊
  static void _paintDirect(Canvas canvas, RRect card, Color color) {
    canvas.drawRRect(
      card.shift(const Offset(0, MeowFrostStyle.dropDy)),
      Paint()
        ..color = color
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
    canvas.drawRRect(
      card.shift(const Offset(0, 1)),
      Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
    );
  }

  static void _paintNine(Canvas canvas, Rect card, double r, Color color, double dpr) {
    final scale = math.min(dpr, 1.5);
    final image = _image(r, color, scale);
    final m = margin, c = (m + r + _spread) * scale;
    canvas.save();
    canvas.scale(1 / scale);
    canvas.drawImageNine(
      image,
      Rect.fromLTWH(c, c, scale, scale),
      Rect.fromLTRB((card.left - m) * scale, (card.top - m) * scale, (card.right + m) * scale, (card.bottom + m) * scale),
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }
}

/// 跟着这些动画让屏幕上的玻璃卡片逐帧按新位置重画（切 Tab 平推、页面转场）：在动画推进的那一刻（这一帧的 build 之前）叫醒，
/// 和页面位移同一帧画——以前靠每帧画完后的位置核对，卡片里的背景总晚一帧、隔一帧才动一次，看起来一顿一顿的。
class MeowFrostFollow extends StatefulWidget {
  const MeowFrostFollow({super.key, required this.animations, required this.child});

  final List<Listenable> animations;
  final Widget child;

  @override
  State<MeowFrostFollow> createState() => _MeowFrostFollowState();
}

class _MeowFrostFollowState extends State<MeowFrostFollow> {
  @override
  void initState() {
    super.initState();
    for (final a in widget.animations) {
      a.addListener(MeowFrostBox.markAllMoved);
    }
  }

  @override
  void didUpdateWidget(MeowFrostFollow old) {
    super.didUpdateWidget(old);
    for (final a in old.animations) {
      a.removeListener(MeowFrostBox.markAllMoved);
    }
    for (final a in widget.animations) {
      a.addListener(MeowFrostBox.markAllMoved);
    }
  }

  @override
  void dispose() {
    for (final a in widget.animations) {
      a.removeListener(MeowFrostBox.markAllMoved);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
