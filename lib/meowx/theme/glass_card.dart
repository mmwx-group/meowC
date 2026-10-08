import 'package:flutter/material.dart';

import 'tokens.dart';

/// 通用卡片：纯色卡片底，圆角默认 24。[MeowTokens.cardEdge] 在新主题里是透明的（白卡配奶白底不需要描边），传 [border] 可覆盖。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding = const EdgeInsets.all(14),
    this.color,
    this.border,
    this.onTap,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final BoxBorder? border;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      decoration: BoxDecoration(
        color: color ?? context.mm.elev,
        borderRadius: BorderRadius.circular(radius),
        border: border ?? Border.all(color: context.mm.cardEdge),
      ),
      padding: padding,
      child: child,
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: body,
      ),
    );
  }
}
