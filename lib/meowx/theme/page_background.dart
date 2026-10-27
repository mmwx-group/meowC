import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'tokens.dart';

/// 页面底怎么画：经典与液态玻璃选「白」时是平涂 [color]；液态玻璃的其它底色是渐层 [gradient]，按**整屏**铺（[size] = 屏幕尺寸）：
/// 单色底色是自上而下的轻渐层，渐变底色（[diagonal]）是左上 → 右下的斜向渐变。页面、转场时盖的那层底色、展开代理组时盖在节点卡上的那层，
/// 各自只画屏幕上的一块，拼起来是同一片渐层，所以都要按自己在屏幕上的位置取色（[paint] 的 origin）。
///
/// 按位置取色的那块要在位置变了时重画：别把它放进会被整块平移、又不重画的 RepaintBoundary 里（平移中的页面：
/// 页面路由与 Tab 平推都把底画在 RepaintBoundary 外面，见 page_route.dart / tab_stack.dart）。
@immutable
class MeowBgFill {
  const MeowBgFill(this.color, this.gradient, this.size, {this.diagonal = false});

  factory MeowBgFill.of(BuildContext context) {
    final mm = context.mm;
    final gradient = mm.bgGradient;
    // 没有渐层时不依赖屏幕尺寸（经典主题不因窗口改尺寸多重建）
    return MeowBgFill(
      mm.bg,
      gradient,
      gradient == null ? Size.zero : MediaQuery.sizeOf(context),
      diagonal: gradient != null && mm.bgDiagonal,
    );
  }

  final Color color;
  final List<Color>? gradient;
  final Size size;
  final bool diagonal;

  bool get flat => gradient == null;

  /// 在 [rect] 里画底；[origin] = [rect] 左上角在屏幕上的位置，[opacity] < 1 时画成半透明（转场里往底色淡）。
  void paint(Canvas canvas, Rect rect, {Offset origin = Offset.zero, double opacity = 1}) {
    final g = gradient;
    if (g == null) {
      final c = color.withValues(alpha: color.a * opacity);
      if (c.a > 0) canvas.drawRect(rect, Paint()..color = c);
      return;
    }
    if (opacity <= 0) return;
    // 屏幕左上角在这块画布上的位置
    final screen = rect.topLeft - origin;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          diagonal ? screen : Offset(0, screen.dy),
          diagonal ? screen + Offset(size.width, size.height) : Offset(0, screen.dy + size.height),
          [for (final c in g) c.withValues(alpha: c.a * opacity)],
        ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MeowBgFill &&
      other.color == color &&
      other.size == size &&
      other.diagonal == diagonal &&
      (identical(other.gradient, gradient) ||
          (other.gradient != null &&
              gradient != null &&
              other.gradient!.length == gradient!.length &&
              Iterable.generate(gradient!.length).every((i) => other.gradient![i] == gradient![i])));

  @override
  int get hashCode => Object.hash(color, size, diagonal, gradient == null ? null : Object.hashAll(gradient!));
}

/// 页面底（替原来的 `ColoredBox(color: mm.bg)`）：平涂时画出来与那个 [ColoredBox] 一样；有渐层时按屏幕位置画渐层。
/// 与 [ColoredBox] 一样整块接住点按（底下的页面点不到）。平涂与渐层是同一种 widget：换底色时子树不拆掉重建。
class MeowPageBackground extends StatelessWidget {
  const MeowPageBackground({super.key, this.hostedByRoute = false, this.child});

  /// 外面的路由已经在 RepaintBoundary 外面画了整屏底（手机上的二级页，见 page_route.dart）：渐层时这里不再画——
  /// 页面在 RepaintBoundary 里，第一次画在转场半路上、停下后不重画，按位置取的色会错位。平涂时照旧画（与原来一样）
  final bool hostedByRoute;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final fill = MeowBgFill.of(context);
    return MeowBgBox(fill: fill, opacity: hostedByRoute && !fill.flat ? 0 : 1, child: child);
  }
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

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size > Size.zero) {
      // 这块在屏幕上的位置（画渐层要用）
      final origin = _fill.flat ? Offset.zero : localToGlobal(Offset.zero);
      _fill.paint(context.canvas, offset & size, origin: origin, opacity: _opacity);
    }
    super.paint(context, offset);
  }
}
