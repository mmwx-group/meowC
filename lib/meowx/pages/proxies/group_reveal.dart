import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme/motion.dart';
import '../../theme/page_background.dart';

/// 列表布局里一个组正在展开 / 收起的那一段动画（只在用户点组卡时建，播完就扔；滚动回来、重建都不重播）。
/// - [height]：容器露出的比例。展开 = soft 弹簧到 1（微回弹）；收起 = 延后 60ms、240ms 收到 0。
/// - [clock]：节点卡错峰的时钟（线性 0…1，乘总时长就是毫秒），每张卡按自己的序号从 [Stagger] 取进度。
class GroupReveal {
  GroupReveal({required TickerProvider vsync, required this.count, required double from})
    : height = AnimationController.unbounded(vsync: vsync, value: from),
      clock = AnimationController(vsync: vsync);

  final AnimationController height;
  final AnimationController clock;

  /// 组里的节点数（收起时倒序要知道谁是最后一张）
  int count;
  bool opening = true;
  int _total = 0;
  int _generation = 0;

  Listenable get items => clock;

  double get _elapsed => clock.value * _total;

  /// 第 [index] 张卡此刻的不透明度与向下位移。
  ({double opacity, double dy}) item(int index) =>
      opening ? Stagger.itemIn(index, _elapsed) : Stagger.itemOut(index, count, _elapsed);

  /// 展开；播完调 [onDone]（中途被反向打断的不调）。
  void open(VoidCallback onDone) {
    opening = true;
    _run(Stagger.inTotal(count), MeowMotion.spring(height, 1, MeowMotion.soft), onDone);
  }

  /// 收起；播完调 [onDone]。
  void close(VoidCallback onDone) {
    opening = false;
    const total = Stagger.collapseDelay + Stagger.collapseDuration;
    final h = height.animateTo(
      0,
      duration: const Duration(milliseconds: total),
      curve: const Interval(Stagger.collapseDelay / total, 1, curve: MeowMotion.standard),
    );
    _run(Stagger.outTotal(count), h, onDone);
  }

  void _run(int totalMs, TickerFuture heightDone, VoidCallback onDone) {
    final gen = ++_generation;
    _total = totalMs;
    clock.duration = Duration(milliseconds: totalMs <= 0 ? 1 : totalMs);
    final items = clock.forward(from: 0);
    Future.wait([heightDone.orCancel, items.orCancel]).then((_) {
      if (gen == _generation) onDone();
    }, onError: (_) {});
  }

  void dispose() {
    _generation++;
    height.dispose();
    clock.dispose();
  }
}

/// 节点卡（以及「自动选择」行）的错峰出现 / 淡出。[reveal] 为 null = 静止，原样画（结构不变，动画结束时不重建子树）。
///
/// 淡入淡出不用 [Opacity]：不透明度在 0 和 1 之间时每张卡都是一个离屏层（saveLayer），一屏十几张卡同时淡入就是十几个，
/// 低端机展开一组明显掉帧。这些卡直接铺在页面底色上，所以照 FlClash 0.9.1 页面转场的做法，在卡上盖一层页面底色、
/// 按进度变淡（[_BgFade]），看起来和淡入一样，不开离屏层。
///
/// 卡片本身包在自己的 [RepaintBoundary] 里、放在位移的里面：动画每帧只改位移图层与盖的那层底色，卡片内容（文字、图标、徽标）
/// 只画一次。所以网格不要再给每格自动套一层 RepaintBoundary（[NodeSliverGrid] 里关掉了 addRepaintBoundaries），这里这层就是那一层。
class StaggeredItem extends StatelessWidget {
  const StaggeredItem({super.key, required this.reveal, required this.index, required this.child});

  final GroupReveal? reveal;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final r = reveal;
    final bg = MeowBgFill.of(context);
    return AnimatedBuilder(
      animation: r?.items ?? kAlwaysCompleteAnimation,
      builder: (_, child) {
        // 静止时也套同样几层（不透明度 1 / 零位移），动画结束时子树不被换掉
        final (:opacity, :dy) = r == null ? (opacity: 1.0, dy: 0.0) : r.item(index);
        return Transform.translate(
          offset: Offset(0, dy),
          child: _BgFade(opacity: opacity, fill: bg, child: child),
        );
      },
      child: RepaintBoundary(child: child),
    );
  }
}

/// 把子树往 [fill]（页面底）淡：先画子树，再在上面盖一层按 1 − [opacity] 透明度的页面底；完全透明时不画子树。
class _BgFade extends SingleChildRenderObjectWidget {
  const _BgFade({required this.opacity, required this.fill, super.child});

  final double opacity;
  final MeowBgFill fill;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBgFade(opacity, fill);

  @override
  void updateRenderObject(BuildContext context, _RenderBgFade renderObject) {
    renderObject
      ..opacity = opacity
      ..fill = fill;
  }
}

class _RenderBgFade extends RenderProxyBox {
  _RenderBgFade(this._opacity, this._fill);

  double _opacity;
  MeowBgFill _fill;

  set opacity(double value) {
    if (value == _opacity) return;
    _opacity = value;
    markNeedsPaint();
  }

  set fill(MeowBgFill value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || _opacity <= 0) return;
    super.paint(context, offset);
    if (_opacity < 1) {
      if (_fill.flat) {
        final color = _fill.color;
        context.canvas.drawRect(offset & size, Paint()..color = color.withValues(alpha: color.a * (1 - _opacity)));
      } else {
        // 渐层的页面底：按这张卡在屏幕上的位置取色，盖上去与周围的底接得上
        _fill.paint(context.canvas, offset & size, origin: localToGlobal(Offset.zero), opacity: 1 - _opacity);
      }
    }
  }
}
