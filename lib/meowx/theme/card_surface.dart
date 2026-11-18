import 'package:flutter/material.dart';

import 'tokens.dart';

/// 内容卡片的底（网速卡、订阅卡、指标格、出口 IP、各页列表卡……）：实色 [BoxDecoration]。
/// M3 改版（2026-11）后不再有磨砂玻璃卡片，卡片底 = [MeowCardColors.card]（[MeowTokens.elev]）。
extension MeowCardSurface on MeowTokens {
  /// 卡片的 decoration：[color] 缺省 = 卡片底 [MeowTokens.elev]。[openTop] / [openBottom] 留给旧调用点（一张卡片中间的一截），现在没有区别。
  Decoration card(BorderRadiusGeometry radius, {Color? color, bool openTop = false, bool openBottom = false}) =>
      BoxDecoration(color: color ?? elev, borderRadius: radius);
}

/// 卡片形状的 [Material]（点按水波、形状描边由它画）。
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

  @override
  Widget build(BuildContext context) => Material(
    color: color ?? context.mm.elev,
    borderRadius: borderRadius,
    shape: shape,
    clipBehavior: clipBehavior,
    child: child,
  );
}

/// 内容卡片：`Container(decoration: BoxDecoration(color, borderRadius))`。[color] 缺省 = 卡片底。
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
  Widget build(BuildContext context) => Container(
    width: width,
    padding: padding,
    constraints: constraints,
    clipBehavior: clipBehavior,
    decoration: BoxDecoration(color: color ?? context.mm.elev, borderRadius: radius),
    child: child,
  );
}
