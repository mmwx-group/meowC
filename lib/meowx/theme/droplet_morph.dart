import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// iOS 27 弹出菜单 / popover 的「水滴」变形（2026-11-18 对着 iOS 27 模拟器录屏逐帧照抄；用户说上一版「完全不一样」）：
/// - 从按钮中心冒出一颗圆形的水滴（直径约按钮高），不是从按钮的矩形长出来；
/// - 约 0.1 秒长成面板、约 0.25 秒停住，中途冲过头一点再回来；形状一路是「短边一半」的圆角，快到位才收成面板的圆角；
/// - 内容一开始就在，跟着面板一起被拉伸（不是钉在最终位置、面板只裁出一块），先糊后清；
/// - 关：内容糊掉、面板缩回按钮中心的水滴，约 0.18 秒，最后一点淡掉。
abstract final class DropletMorph {
  /// 开的弹簧：约 0.25 秒停住、冲过头约 5%
  static final spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.68);

  /// 关的时长与曲线
  static const closeDuration = Duration(milliseconds: 180);
  static const closeCurve = Curves.easeInCubic;

  /// 起点：按钮中心的一颗圆（直径按按钮短边，夹在 28–56）
  static Rect start(Rect anchor) {
    final d = anchor.shortestSide.clamp(28.0, 56.0);
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
  static double panelOpacity(double p) => (p / 0.12).clamp(0.0, 1.0);

  /// 面板里的内容：按最终尺寸排好，再随面板矩形 [r] 拉伸（宽高各自缩放），先糊后清。
  /// [blur] = false（低端机 / 移除动画）时不糊，只拉伸 + 淡入。
  static Widget content({
    required Widget child,
    required Rect r,
    required Rect target,
    required double p,
    required bool blur,
  }) {
    final pc = p.clamp(0.0, 1.0);
    final sx = target.width <= 0 ? 1.0 : r.width / target.width;
    final sy = target.height <= 0 ? 1.0 : r.height / target.height;
    Widget c = OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: target.width,
      maxWidth: target.width,
      minHeight: target.height,
      maxHeight: target.height,
      child: Transform(
        alignment: Alignment.topLeft,
        transform: Matrix4.diagonal3Values(sx, sy, 1),
        child: child,
      ),
    );
    final sigma = blur ? 9 * math.pow(1 - pc, 2).toDouble() : 0.0;
    if (sigma > 0.3) c = ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: c);
    return Opacity(opacity: (pc * 2.5).clamp(0.0, 1.0), child: c);
  }
}

/// 把 [DropletMorph.spring] 按 [duration] 归一成曲线（给用路由动画驱动的 popover 用）；末尾钉在 1。
class DropletSpringCurve extends Curve {
  const DropletSpringCurve();

  static const duration = Duration(milliseconds: 420);

  @override
  double transformInternal(double t) {
    final sim = SpringSimulation(DropletMorph.spring, 0, 1, 0);
    return sim.x(t * duration.inMicroseconds / 1e6);
  }
}
