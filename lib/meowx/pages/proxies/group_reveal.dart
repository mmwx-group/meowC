import 'package:flutter/material.dart';

import '../../theme/motion.dart';

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
/// 卡片本身包在自己的 [RepaintBoundary] 里、放在位移的里面：动画每帧只改透明度图层与位移图层，卡片内容（文字、图标、徽标）
/// 只画一次。以前位移在边界外面，每帧每张卡都要重画一遍。所以网格不要再给每格自动套一层 RepaintBoundary
/// （[NodeSliverGrid] 里关掉了 addRepaintBoundaries），这里这层就是那一层。
class StaggeredItem extends StatelessWidget {
  const StaggeredItem({super.key, required this.reveal, required this.index, required this.child});

  final GroupReveal? reveal;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final r = reveal;
    return AnimatedBuilder(
      animation: r?.items ?? kAlwaysCompleteAnimation,
      builder: (_, child) {
        // 静止时也套同样几层（不透明度 1 / 零位移），动画结束时子树不被换掉
        final (:opacity, :dy) = r == null ? (opacity: 1.0, dy: 0.0) : r.item(index);
        return Opacity(
          opacity: opacity,
          child: Transform.translate(offset: Offset(0, dy), child: child),
        );
      },
      child: RepaintBoundary(child: child),
    );
  }
}
