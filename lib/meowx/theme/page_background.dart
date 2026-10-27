import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'tokens.dart';

/// 页面底怎么画：经典与液态玻璃选「白」时是平涂 [color]；液态玻璃选了别的底色时是自上而下的轻渐层 [gradient]，
/// 按**整屏**铺（[height] = 屏高）——页面、转场时盖的那层底色、展开代理组时盖在节点卡上的那层，各自只画屏幕上的一截，
/// 拼起来是同一条渐层，所以都要按自己在屏幕上的位置取色（[paint] 的 globalTop）。
@immutable
class MeowBgFill {
  const MeowBgFill(this.color, this.gradient, this.height);

  factory MeowBgFill.of(BuildContext context) {
    final mm = context.mm;
    final gradient = mm.bgGradient;
    // 没有渐层时不依赖屏高（经典主题不因窗口改尺寸多重建）
    return MeowBgFill(mm.bg, gradient, gradient == null ? 0 : MediaQuery.sizeOf(context).height);
  }

  final Color color;
  final List<Color>? gradient;
  final double height;

  bool get flat => gradient == null;

  /// 在 [rect] 里画底；[globalTop] = [rect] 的顶在屏幕上的 y，[opacity] < 1 时画成半透明（转场里往底色淡）。
  void paint(Canvas canvas, Rect rect, {double globalTop = 0, double opacity = 1}) {
    final g = gradient;
    if (g == null) {
      final c = color.withValues(alpha: color.a * opacity);
      if (c.a > 0) canvas.drawRect(rect, Paint()..color = c);
      return;
    }
    if (opacity <= 0) return;
    final top = rect.top - globalTop;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, top),
          Offset(0, top + height),
          [for (final c in g) c.withValues(alpha: c.a * opacity)],
        ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MeowBgFill &&
      other.color == color &&
      other.height == height &&
      (identical(other.gradient, gradient) ||
          (other.gradient != null &&
              gradient != null &&
              other.gradient!.length == gradient!.length &&
              Iterable.generate(gradient!.length).every((i) => other.gradient![i] == gradient![i])));

  @override
  int get hashCode => Object.hash(color, height, gradient == null ? null : Object.hashAll(gradient!));
}

/// 页面底（替原来的 `ColoredBox(color: mm.bg)`）：平涂时画出来与那个 [ColoredBox] 一样；有渐层时按屏幕位置画渐层。
/// 与 [ColoredBox] 一样整块接住点按（底下的页面点不到）。平涂与渐层是同一种 widget：换底色时子树不拆掉重建。
class MeowPageBackground extends StatelessWidget {
  const MeowPageBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => MeowBgBox(fill: MeowBgFill.of(context), child: child);
}

/// 按屏幕位置画 [fill]（[opacity] = 画多浓），再画子树。
class MeowBgBox extends SingleChildRenderObjectWidget {
  const MeowBgBox({super.key, required this.fill, this.opacity = 1, super.child});

  final MeowBgFill fill;
  final double opacity;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderMeowBgBox(fill, opacity);

  @override
  void updateRenderObject(BuildContext context, RenderMeowBgBox renderObject) {
    renderObject
      ..fill = fill
      ..opacity = opacity;
  }
}

class RenderMeowBgBox extends RenderProxyBoxWithHitTestBehavior {
  RenderMeowBgBox(this._fill, this._opacity) : super(behavior: HitTestBehavior.opaque);

  MeowBgFill _fill;
  set fill(MeowBgFill v) {
    if (v == _fill) return;
    _fill = v;
    markNeedsPaint();
  }

  double _opacity;
  set opacity(double v) {
    if (v == _opacity) return;
    _opacity = v;
    markNeedsPaint();
  }

  /// 这块在屏幕上的 y（画渐层要用）
  double get globalTop => _fill.flat ? 0 : localToGlobal(Offset.zero).dy;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size > Size.zero) _fill.paint(context.canvas, offset & size, globalTop: globalTop, opacity: _opacity);
    super.paint(context, offset);
  }
}
