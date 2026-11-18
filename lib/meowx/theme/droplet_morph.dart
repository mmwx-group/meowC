import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// iOS 27 弹出菜单 / popover 的「水滴」变形（2026-11-18 对着 iOS 27 模拟器录屏逐帧照抄，第二版）：
/// - 从按钮中心冒出一颗小的圆形玻璃水滴（一出来就是玻璃、透出背后放大发糊的画面），不是从按钮的矩形长出来；
/// - 约 0.3 秒长成面板、冲过头约 3% 再回来；形状一路是「短边一半」的圆角（圆 → 胶囊），快到位才收成面板的圆角；
/// - 内容按最终尺寸钉在最终位置，面板只是把它一点点露出来（不跟着面板拉伸——第一版拉伸了，用户说内容没有自适应）；
///   前三成只看得到玻璃，之后内容由糊变清；
/// - 关：内容糊掉、面板缩回按钮中心的水滴，约 0.16 秒，最后一点淡掉。
abstract final class DropletMorph {
  /// 开的弹簧：约 0.3 秒停住、冲过头约 3%
  static final spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.75);

  /// 关的时长与曲线
  static const closeDuration = Duration(milliseconds: 160);
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
    final sigma = blur ? 12 * (1 - ease(0.3, 0.85)) : 0.0;
    if (sigma > 0.3) c = ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: c);
    return Opacity(opacity: ease(0.3, 0.75), child: c);
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
