import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 按比例露出一个 sliver：对外报的长度 = 子 sliver 的长度 × [factor]，超出的部分裁掉。
/// 用来给 CustomScrollView 里展开 / 收起的一段（懒加载的节点网格）做「容器高度」动画——不把网格换成非懒加载的盒子，
/// 也不套 SliverMainAxisGroup（它滚动后的命中测试有偏移）。[factor] 可以略大于 1（弹簧回弹），多出来的是空白。
/// 只按向下滚动的竖直列表写（本项目只这么用）。
class SliverReveal extends SingleChildRenderObjectWidget {
  const SliverReveal({super.key, required this.factor, required Widget sliver}) : super(child: sliver);

  final double factor;

  @override
  RenderSliverReveal createRenderObject(BuildContext context) => RenderSliverReveal(factor);

  @override
  void updateRenderObject(BuildContext context, RenderSliverReveal renderObject) => renderObject.factor = factor;
}

class RenderSliverReveal extends RenderProxySliver {
  RenderSliverReveal(this._factor);

  double _factor;
  double get factor => _factor;
  set factor(double v) {
    if (v == _factor) return;
    _factor = v;
    markNeedsLayout();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  bool get _full => _factor == 1;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      geometry = SliverGeometry.zero;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    final g = child.geometry!;
    if (_full || g.scrollOffsetCorrection != null) {
      geometry = g;
      return;
    }
    final extent = math.max(0.0, g.scrollExtent * _factor);
    final paint = calculatePaintOffset(constraints, from: 0, to: extent);
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: paint,
      layoutExtent: paint,
      maxPaintExtent: extent,
      hitTestExtent: paint,
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: extent),
      hasVisualOverflow: true,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || !geometry!.visible) {
      _clip.layer = null;
      return;
    }
    if (_full) {
      _clip.layer = null;
      context.paintChild(child, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & Size(constraints.crossAxisExtent, geometry!.paintExtent),
      (c, o) => c.paintChild(child, o),
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
