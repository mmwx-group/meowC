import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// iOS 27 弹出菜单 / popover 的「水滴」变形（2026-11-18 对着 iOS 27 模拟器录屏逐帧照抄，第二版）：
/// - 从按钮中心冒出一颗小的圆形玻璃水滴（一出来就是玻璃、透出背后放大发糊的画面），不是从按钮的矩形长出来；
/// - 从小到大慢慢长：约 0.21 秒到顶、冲过头约 8% 再弹回来，约 0.35 秒停住（第二版只冲 3%，用户说回弹没了；
///   第三版太快，用户说一瞬间就展开了；第四版 0.3 秒到顶，用户说比 iOS 27 慢，现在约 0.21 秒）。动画在气泡第一帧画出来之后才开始计时；形状一路是「短边一半」的圆角（圆 → 胶囊），快到位才收成面板的圆角；
/// - 内容按最终尺寸钉在最终位置，面板只是把它一点点露出来（不跟着面板拉伸——第一版拉伸了，用户说内容没有自适应）；
///   前一半只看得到玻璃，之后内容才由糊变清（展开途中内容不完整显示）；
/// - 关：内容糊掉、面板缩回按钮中心的水滴，约 0.13 秒，最后一点淡掉。
abstract final class DropletMorph {
  /// 开的弹簧：约 0.21 秒到顶、冲过头约 8%（看得出「啵」地弹一下）、约 0.35 秒停住
  /// （2026-11-18 用户：比 iOS 27 慢。以前 170 / 0.6 是 0.3 秒到顶；计时从气泡第一帧开始，不会再「一瞬间就展开」）
  static final spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 360, ratio: 0.62);

  /// 关的时长与曲线
  static const closeDuration = Duration(milliseconds: 130);
  static const closeCurve = Curves.easeInCubic;

  /// 起点：按钮中心的一颗小圆（直径约按钮短边的七成，夹在 24–44）
  static Rect start(Rect anchor) {
    final d = (anchor.shortestSide * 0.7).clamp(24.0, 44.0);
    return Rect.fromCenter(center: anchor.center, width: d, height: d);
  }

  /// 进度 [p]（可越过 1）对应的面板矩形
  static Rect rect(Rect anchor, Rect target, double p) => Rect.lerp(start(anchor), target, p)!;

  /// 圆角：前段是短边一半（圆 / 胶囊），后段才收成 [finalRadius]
  static double radius(Rect r, double finalRadius, double p) {
    final pc = p.clamp(0.0, 1.0);
    final round = r.shortestSide / 2;
    return math.min(round, lerpDouble(round, finalRadius, Curves.easeInQuad.transform(pc))!);
  }

  /// 整块面板的不透明度：只在最开头 / 最末尾那一点淡入淡出（水滴不是凭空「啪」地出现）
  static double panelOpacity(double p) => (p / 0.08).clamp(0.0, 1.0);

  /// 玻璃的厚度：一出来就是玻璃（iOS 的水滴从第一帧就在折射背后的画面），只略微随进度加厚
  static double glassAmount(double p) => 0.65 + 0.35 * p.clamp(0.0, 1.0);

  /// 面板里的内容：按最终尺寸排好、钉在最终位置（[target] 左上角），面板 [r] 只是把它露出一部分；先糊后清。
  /// [blur] = false（低端机 / 移除动画）时不糊，只淡入。
  static Widget content({
    required Widget child,
    required Rect r,
    required Rect target,
    required double p,
    required bool blur,
  }) {
    final pc = p.clamp(0.0, 1.0);
    Widget c = OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: target.width,
      maxWidth: target.width,
      minHeight: target.height,
      maxHeight: target.height,
      child: Transform.translate(offset: target.topLeft - r.topLeft, child: child),
    );
    double ease(double a, double b) => Curves.easeOut.transform(((pc - a) / (b - a)).clamp(0.0, 1.0));
    final sigma = blur ? 14 * (1 - ease(0.45, 1.0)) : 0.0;
    // 模糊层一直在树上（只开关）：插拔它会让里面的内容整棵重挂、每帧重画
    c = ImageFiltered(
      enabled: sigma > 0.3,
      imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: c,
    );
    return Opacity(opacity: ease(0.5, 0.95), child: c);
  }
}

/// 把 [DropletMorph.spring] 按 [duration] 归一成曲线（给用路由动画驱动的 popover 用）；末尾钉在 1。
class DropletSpringCurve extends Curve {
  const DropletSpringCurve();

  static const duration = Duration(milliseconds: 500);

  @override
  double transformInternal(double t) {
    final sim = SpringSimulation(DropletMorph.spring, 0, 1, 0);
    return sim.x(t * duration.inMicroseconds / 1e6);
  }
}

/// 气泡 / 菜单背后的「透明挡板」（同 iOS 27：气泡开着时照样能滑页面）：
/// - 点外面 = 只关气泡，这一下不落到下面的按钮上（挡板的点按识别器排在手势竞技场最前面，先赢）；
/// - 在外面拖 = 气泡马上淡掉（[onHide]），下面的列表照常滚；手指抬起后才真正关路由（[onDismiss]）——
///   Navigator 每次 push / pop 都会取消所有进行中的触点，拖到一半关路由会把这次滚动连同惯性一起掐断。
/// 用法：路由里 `buildModalBarrier() => DropletPassThroughBarrier(…)`。关闭动画期间路由自己会让挡板忽略指针。
class DropletPassThroughBarrier extends StatefulWidget {
  const DropletPassThroughBarrier({super.key, required this.onHide, required this.onDismiss});
  final VoidCallback onHide, onDismiss;

  @override
  State<DropletPassThroughBarrier> createState() => _DropletPassThroughBarrierState();
}

class _DropletPassThroughBarrierState extends State<DropletPassThroughBarrier> {
  final _downs = <int, Offset>{};
  final _dragging = <int>{};
  bool _hidden = false, _done = false;

  /// 关路由放到这次指针事件分发完之后（抬起的触点已经不在 Navigator 的活动触点里，不会被取消，惯性照常）
  void _dismissLater() {
    if (_done) return;
    _done = true;
    Future.microtask(widget.onDismiss);
  }

  void _end(int pointer) {
    _downs.remove(pointer);
    if (_dragging.remove(pointer) && _dragging.isEmpty) _dismissLater();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (e) => _downs[e.pointer] = e.position,
    onPointerMove: (e) {
      final from = _downs[e.pointer];
      if (from == null || _dragging.contains(e.pointer) || (e.position - from).distance <= kTouchSlop) return;
      _dragging.add(e.pointer);
      if (!_hidden) {
        _hidden = true;
        widget.onHide();
      }
    },
    onPointerUp: (e) => _end(e.pointer),
    onPointerCancel: (e) => _end(e.pointer),
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissLater,
      child: const SizedBox.expand(),
    ),
  );
}

/// 被拖动「先藏起来」的气泡：[hidden] 变真时 120ms 淡掉并不再接触点（路由稍后才真正关）。
class DropletHideOnDrag extends StatelessWidget {
  const DropletHideOnDrag({super.key, required this.hidden, required this.child});
  final ValueListenable<bool> hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: hidden,
    builder: (_, h, child) => IgnorePointer(
      ignoring: h,
      child: AnimatedOpacity(opacity: h ? 0 : 1, duration: const Duration(milliseconds: 120), child: child),
    ),
    child: child,
  );
}
