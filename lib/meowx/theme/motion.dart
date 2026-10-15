import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// MeowX 的动效参数：三档弹簧 + 几条曲线 + 各处的时序。各处都从这里取，不在页面里散写常数。
/// 只动位移 / 缩放 / 透明度 / 颜色 / 尺寸，不动模糊和阴影半径；系统「移除动画」（[reduced]）时直接跳到终态。
abstract final class MeowMotion {
  /// 柔和（展开容器、菜单变形）：微回弹
  static const soft = SpringDescription(mass: 1, stiffness: 170, damping: 22);

  /// 弹跳（电源键补满 / 图标、分段滑块、箭头）
  static const bouncy = SpringDescription(mass: 1, stiffness: 260, damping: 16);

  /// 利落（菜单里的选中块）
  static const snap = SpringDescription(mass: 1, stiffness: 400, damping: 30);

  /// 先快后慢：注入、涟漪、错峰出现
  static const emphasized = Cubic(.2, .8, .3, 1);

  /// 收起 / 关闭
  static const standard = Cubic(.4, 0, .2, 1);

  /// 排空（电源键断开）
  static const drain = Cubic(.5, 0, .8, .4);

  /// 系统设置了「移除动画」。
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// 隐式动画的时长：「移除动画」时为零。
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;

  /// 用弹簧把 [c] 带到 [target]（接着当前速度走，打断也连贯）；[reduce] 时直接跳过去。
  /// [c] 要是 `AnimationController.unbounded`：弹簧会越过终点，有界的控制器会把回弹截掉。
  static TickerFuture spring(AnimationController c, double target, SpringDescription spring, {bool reduce = false}) {
    if (reduce) {
      c.stop();
      c.value = target;
      return TickerFuture.complete();
    }
    return c.animateWith(SpringSimulation(spring, c.value, target, c.velocity));
  }

  // ── 电源键 ──
  static const pourFast = Duration(milliseconds: 1200);
  static const pourCreep = Duration(seconds: 6);
  static const pourFastLevel = 0.7;
  static const pourMaxLevel = 0.92;
  static const ripple = Duration(milliseconds: 650);
  static const drainDuration = Duration(milliseconds: 350);
  static const iconPopFrom = 0.6;

  // ── 切 Tab 的整页平推（同 iOS：新页整页推入、旧页反向退 30%，不改透明度）──
  static const tabSlide = Duration(milliseconds: 380);

  /// 临界阻尼、无回弹（iOS 那边是 dampingRatio 1 的弹簧）
  static const tabSlideCurve = Curves.easeOutCubic;

  /// 旧页退开的距离（页宽的比例）
  static const tabParallax = 0.3;

  // ── 两态颜色渐变（分段文字、图标颜色）──
  static const colorFade = Duration(milliseconds: 220);

  // ── 弹出菜单 ──
  static const menuTriggerOut = Duration(milliseconds: 120);
  static const menuItemDelay = 140, menuItemStep = 18, menuItemFade = 200;
  static const menuItemsOut = Duration(milliseconds: 90);
  static const menuPanelClose = Duration(milliseconds: 260);

  /// 关闭开始后多久按钮开始淡回、淡回用多久；面板留到按钮完全回来才撤（两者叠着交叉淡化，不闪）
  static const menuTriggerBackDelay = 200, menuTriggerBack = 120;
  static const menuCloseTotal = Duration(milliseconds: menuTriggerBackDelay + menuTriggerBack);
  static const menuAutoClose = Duration(milliseconds: 220);

  /// 菜单第 [index] 项淡入的进度（0…1，已过 ease-out）；[elapsedMs] 从开始变形算起。前 12 项错峰，之后的与第 12 项同时。
  static double menuItemIn(int index, double elapsedMs) {
    final start = menuItemDelay + math.min(index, Stagger.cap - 1) * menuItemStep;
    return Curves.easeOut.transform(((elapsedMs - start) / menuItemFade).clamp(0.0, 1.0));
  }

  /// [count] 项的菜单淡入总时长（毫秒）。
  static int menuItemsTotal(int count) =>
      count <= 0 ? 0 : menuItemDelay + math.min(count - 1, Stagger.cap - 1) * menuItemStep + menuItemFade;
}

/// 代理组展开 / 收起时组内节点卡的错峰时序（毫秒）。只给前 [cap] 张错峰，之后的与第 [cap] 张同一时刻——节点多的组不拖长。
abstract final class Stagger {
  static const cap = 12;
  static const inDelay = 40, inStep = 25, inDuration = 320, inShift = 10.0;
  static const outStep = 15, outDuration = 140, outShift = 6.0;

  /// 收起时容器高度：延后 60ms 开始，240ms 收完
  static const collapseDelay = 60, collapseDuration = 240;

  static int _slot(int index) => math.min(math.max(index, 0), cap - 1);

  /// 展开时第 [index] 张卡开始出现的时刻。
  static int inStart(int index) => inDelay + _slot(index) * inStep;

  /// [count] 张卡全部出现完的时刻。
  static int inTotal(int count) => count <= 0 ? 0 : inStart(count - 1) + inDuration;

  /// 收起时第 [index] 张卡开始淡出的时刻（倒序：最后一张先走）。
  static int outStart(int index, int count) => (_slot(count - 1) - _slot(index)) * outStep;

  /// [count] 张卡全部淡出完的时刻。
  static int outTotal(int count) => count <= 0 ? 0 : outStart(0, count) + outDuration;

  /// 展开中第 [index] 张卡：不透明度与向下的位移。
  static ({double opacity, double dy}) itemIn(int index, double elapsedMs) {
    final t = MeowMotion.emphasized.transform(((elapsedMs - inStart(index)) / inDuration).clamp(0.0, 1.0));
    return (opacity: t, dy: inShift * (1 - t));
  }

  /// 收起中第 [index] 张卡（共 [count] 张）：不透明度与向下的位移。
  static ({double opacity, double dy}) itemOut(int index, int count, double elapsedMs) {
    final t = Curves.easeIn.transform(((elapsedMs - outStart(index, count)) / outDuration).clamp(0.0, 1.0));
    return (opacity: 1 - t, dy: outShift * t);
  }
}

/// 电源键「连接中」的液面：[from] 起 1.2s 先快后慢注到七成，之后 6s 线性涨到 0.92，停在那里（久连不上也不会注满）。
double pourLevel(double from, Duration elapsed) {
  final ms = elapsed.inMicroseconds / 1000;
  final fast = MeowMotion.pourFast.inMilliseconds;
  if (ms < fast) {
    final start = math.min(from, MeowMotion.pourFastLevel);
    return start + (MeowMotion.pourFastLevel - start) * MeowMotion.emphasized.transform(ms / fast);
  }
  final creep = ((ms - fast) / MeowMotion.pourCreep.inMilliseconds).clamp(0.0, 1.0);
  return MeowMotion.pourFastLevel + (MeowMotion.pourMaxLevel - MeowMotion.pourFastLevel) * creep;
}

/// [pourLevel] 的模拟版，交给 `AnimationController.animateWith`。
class PourSimulation extends Simulation {
  PourSimulation(this.from);
  final double from;

  static final _end = MeowMotion.pourFast + MeowMotion.pourCreep;

  Duration _at(double t) => Duration(microseconds: (t * 1e6).round());

  @override
  double x(double time) => pourLevel(from, _at(time));

  @override
  double dx(double time) => (x(time + 0.001) - x(time)) / 0.001;

  @override
  bool isDone(double time) => _at(time) >= _end;
}
