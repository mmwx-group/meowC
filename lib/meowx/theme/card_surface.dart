import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 内容卡片的底（网速卡、订阅卡、指标格、出口 IP、各页列表卡……）。
///
/// 经典主题：就是原来那份实色 [BoxDecoration]（一个像素不变）。
/// 液态玻璃主题：「静态玻璃」——半透明底 + 1px 亮边 + 顶边一道内高光 + 很淡的同色相投影（[MeowCardDecoration]）。
/// 不挂实时模糊（BackdropFilter）：页面底是平涂 / 柔和渐层，背后没有东西可折射；安卓上逐卡模糊是以前卡顿的原因。
/// 真正取背景的液态玻璃仍只在浮层控件上（glass.dart）。
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
/// 液态玻璃主题下底由 [MeowCardDecoration] 画，[Material] 本身透明、只管水波与裁剪。
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
    return DecoratedBox(
      decoration: mm.card(_radius, color: color),
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
