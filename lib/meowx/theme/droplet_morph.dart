import 'dart:math' as math;
import 'dart:ui' show ImageFilter, PathOperation, lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart' show Ticker, TickerProvider;

import '../glass/liquid_glass.dart';
import 'glass.dart';

// iOS 27 弹出菜单 / popover 的「水滴」变形（第三版，2026-11-19）。
//
// 前两版是对着模拟器录屏目测的：一个矩形从按钮中心的小圆插值到面板，用户说和 iOS 差得多。这一版的曲线照搬
// liquid_glass_widgets 1.18（MIT，© 2024–2026 Sebastian Degenaar，github.com/sdegenaar/liquid_glass_widgets，
// lib/utils/liquid_morph_physics.dart；常数与公式移植自那里，许可声明见 NOTICE.md）——
// 那边对着 iOS 27 原生 Menu / popover 的 CALayer.presentation() 逐帧（60fps）量出来再拟合，代码里留着各时刻的实测值。
// 我们只搬曲线，不搬它的 SDF 着色器：两团玻璃的融合用 Path 画（两圆之间的 metaball 桥 + 合并），玻璃照旧是我们自己那块。
//
// 打开：按钮缩成一颗圆（按钮短边），面板从这颗圆长出来（弹簧 ω₀ 17 / ζ 0.76）；面板中心先往远离按钮的方向冲出去
// （矮菜单约 12px、中等 66px，约 110ms 到顶）再弹回来；前约 140ms 保持正圆，之后约 145ms 才松成面板的圆角；
// 按钮那颗圆在前 40% 缩没，期间和面板之间拉出一条水滴颈；内容 140–240ms 由糊变清淡入。
// 关闭（约 280ms，弹簧 ω₀ 18 / ζ 0.86）：面板以按钮中心为支点等比缩到两成，同时先被推离按钮约 49px 再收回，
// 越缩越圆，最后成一颗倒水滴的尾巴流回按钮；内容立刻糊掉、按缩放线性淡出；玻璃到最后四分之一才化掉。
// 按钮在关闭时被「撞」一下：往菜单的反方向弹约 17px、缩到 0.965，约 183ms 到顶（[DropletMorph.triggerRecoil]）。

/// 一帧的形状与观感（overlay 坐标）
@immutable
class DropletFrame {
  const DropletFrame({
    required this.platter,
    required this.radius,
    this.blobCenter = Offset.zero,
    this.blobRadius = 0,
    this.neck = 0,
    required this.contentOpacity,
    required this.contentBlur,
    required this.glass,
    required this.depth,
  });

  /// 设置好的终态（没有动画时）
  const DropletFrame.settled(Rect target, double radius)
    : this(platter: target, radius: radius, contentOpacity: 1, contentBlur: 0, glass: 1, depth: 1);

  /// 面板（菜单 / 气泡本体）与它的圆角
  final Rect platter;
  final double radius;

  /// 按钮那颗圆（打开时缩没、关闭时在尾巴处冒出来）；半径 0 = 没有
  final Offset blobCenter;
  final double blobRadius;

  /// 面板和按钮那颗圆之间水滴颈能伸多远（px）；0 = 不连
  final double neck;

  /// 内容的不透明度与模糊（σ，px）
  final double contentOpacity;
  final double contentBlur;

  /// 玻璃的浓度（0…1，关闭最后那一段化掉）
  final double glass;

  /// 面板的「厚度」（阴影、细边跟着它，0…1）
  final double depth;

  bool get hasBlob => blobRadius > 0.5;

  /// 整块（面板 + 按钮那颗圆）占的范围
  Rect get bounds =>
      hasBlob ? platter.expandToInclude(Rect.fromCircle(center: blobCenter, radius: blobRadius)) : platter;
}

abstract final class DropletMorph {
  /// 打开：ω₀ = 17 rad/s、ζ ≈ 0.76（约 0.37 秒）
  static const openSpring = SpringDescription(mass: 1, stiffness: 289, damping: 25.8);

  /// 关闭：ω₀ = 18 rad/s、ζ ≈ 0.86（约 0.28 秒面板就没了）
  static const closeSpring = SpringDescription(mass: 1, stiffness: 324, damping: 31);

  /// 关闭动画多久后路由可以拆掉（面板约 280ms 化完）
  static const closeDuration = Duration(milliseconds: 300);

  /// 按钮被撞那一下多久停住
  static const recoilDuration = Duration(milliseconds: 560);

  // ─── 打开 ───

  /// 打开的一帧：[raw] 是打开弹簧的值（0→1，会略冲过 1），[elapsed] 是从打开起的秒数。
  /// [allowed] 给了的话，面板冲出去时不越出这块（安全区），除非按钮本身就在外面。
  static DropletFrame open({
    required Rect anchor,
    required Rect target,
    required double finalRadius,
    required double raw,
    required double elapsed,
    Rect? allowed,
  }) {
    final u = raw.clamp(0.0, 1.0);
    final core = _core(anchor);
    final scaleDelta = _scaleDelta(core.size, target.size);
    // 面积放大三倍以上（菜单都是）尺寸长得比弹簧快（实测 33/67/100/133/167ms 时 0.37/0.58/0.77/0.90/0.99）
    final sizeP = scaleDelta > 3 ? math.pow(u, 0.55).toDouble() : Curves.linearToEaseOut.transform(u);
    final w = lerpDouble(core.width, target.width, sizeP)!;
    final h = lerpDouble(core.height, target.height, sizeP)!;
    final travel = target.center - core.center;
    // 位置走一条比尺寸超前的 J 形曲线：两者之差就是面板领先于「跟着尺寸走」的那一点（横向夹在 ±14）
    final pathT = _BackOut(_backOutAmplitude(travel)).transform(u);
    final anchorScale = (1 - u / 0.4).clamp(0.0, 1.0);
    final release = 1 - anchorScale * 0.65;
    final driftX = (travel.dx * (pathT - sizeP) * release).clamp(-14.0, 14.0);
    final driftY = travel.dy.sign * _openDrift(elapsed, target.height);
    var center = Rect.lerp(core, target, sizeP)!.center + Offset(driftX, driftY);
    if (allowed != null) center = _keepInside(center, Size(w, h), core, allowed);
    final platter = Rect.fromCenter(center: center, width: w, height: h);

    final blend = ((pathT - sizeP).abs() * 150 * _blendAttenuation(scaleDelta)).clamp(0.0, 28.0);
    final t = elapsed - 0.02; // 原生从 open() 到第一帧看得出长大约 20ms
    return DropletFrame(
      platter: platter,
      radius: _openRadius(platter.size, target.size, finalRadius, elapsed),
      blobCenter: core.center,
      blobRadius: core.shortestSide / 2 * anchorScale,
      neck: blend,
      contentOpacity: _smoothstep((t - 0.12) / 0.10),
      contentBlur: 8 * (1 - _smoothstep((t - 0.13) / 0.10)),
      glass: 1,
      depth: sizeP,
    );
  }

  // ─── 关闭 ───

  /// 关闭的一帧：[raw] 是关闭弹簧的值（从关闭那一刻的值 [closeStart] 落到 0），[elapsed] 是从关闭起的秒数。
  /// [menu] = 下拉菜单（按钮被撞的幅度几乎不随距离变），否则是气泡。
  static DropletFrame close({
    required Rect anchor,
    required Rect target,
    required double finalRadius,
    required double raw,
    required double elapsed,
    double closeStart = 1,
    bool menu = true,
  }) {
    final u = raw.clamp(0.0, 1.0);
    final c = closeStart.clamp(0.05, 1.0);
    final core = _core(anchor);
    final tw = anchor.width;
    final minSide = math.min(anchor.width, anchor.height);
    final menuW = target.width, menuH = target.height;
    final pivot = anchor.center;
    final travel = target.center - pivot;

    // 面板以按钮中心为支点等比缩放（0.2 + 0.8u），最后一段地板再往下收，尾巴比按钮还细
    final tailScale = menuW > 0 ? (0.56 * minSide / menuW).clamp(0.08, 0.20) : 0.20;
    final floor = tailScale + (0.20 - tailScale) * _smoothstep(u / 0.24);
    final scale = (floor + (1 - floor) * u).clamp(0.08, 1.0);
    // 高的面板缩得比等比更快：都收成同样长的一滴（约 coreH + 400·u^1.1）
    final coreH = minSide * (0.65 + 0.35 * _smoothstep(u / 0.24));
    final envelope = coreH + 400 * math.pow(u, 1.1) + math.max(0.0, menuH - coreH - 400) * math.pow(u, 2.5);
    final fx = menuW > 0 ? (pivot.dx - target.left) / menuW : 0.5;
    final fy = menuH > 0 ? (pivot.dy - target.top) / menuH : 0.5;
    final w = (menuW * scale).clamp(0.0, menuW);
    final h = math.min(menuH * scale, envelope).clamp(0.0, menuH);
    final scaled = Rect.fromLTWH(pivot.dx - fx * w, pivot.dy - fy * h, w, h);

    final sizeP = ((scale - tailScale) / (1 - tailScale)).clamp(0.0, 1.0);
    final rho0 = (finalRadius / (math.min(menuW, menuH) / 2)).clamp(0.0, 1.0);
    final roundness = 1 - (1 - rho0) * math.pow(sizeP, 2.2);
    final radius = math.min(w, h) / 2 * roundness.clamp(0.0, 1.0);

    // 面板跟着被撞的按钮走一点，同时先被推离按钮再收回（水滴颈就是被这一下拉出来的）
    final push = triggerRecoil(travel, elapsed, closeStart: c, menu: menu);
    final catchUp = push * (1 - u);
    final driftY = travel.dy.sign * _closeDrift(elapsed, menuH) * c;
    final raw0 = scaled.center + catchUp + Offset(0, driftY);
    // 横向在最后收向按钮正下方 / 正上方，且不越过按钮那一侧的外沿
    final converge = _smoothstep((0.36 - u) / 0.28);
    final trigX = pivot.dx + push.dx;
    var cx = raw0.dx + (trigX - raw0.dx) * converge;
    final alignX = _alignX(anchor, target);
    if (alignX < -0.1) {
      cx = math.max(cx, trigX - tw / 2 + w / 2);
    } else if (alignX > 0.1) {
      cx = math.min(cx, trigX + tw / 2 - w / 2);
    }
    final platter = Rect.fromCenter(center: Offset(cx, raw0.dy), width: w, height: h);

    // 按钮那颗圆：等面板缩到够近、时间也到了才冒出来（不出现孤零零的一个点），直接 0.45 起
    final blobCenter = pivot + push;
    final gap = _gap(platter, radius, blobCenter);
    final emerge = math.min(_smoothstep((0.40 - u) / 0.12), _smoothstep((24 - gap) / 11));
    final blobScale = emerge <= 0.001 ? 0.0 : 0.45 + 0.55 * emerge;
    // 融合强度：u 从 0.97 到 0.77 爬到 22，最后 0.16 收掉
    final neck = 22 * _smoothstep((0.97 - u) / 0.20) * (1 - _smoothstep((0.16 - u) / 0.16));

    final cu = (u / c).clamp(0.0, 1.0);
    return DropletFrame(
      platter: platter,
      radius: radius,
      blobCenter: blobCenter,
      blobRadius: core.shortestSide / 2 * blobScale,
      neck: neck,
      contentOpacity: cu,
      contentBlur: (28 * (1 - cu)).clamp(0.0, 8.0),
      glass: (u / 0.25).clamp(0.0, 1.0),
      depth: sizeP,
    );
  }

  // ─── 按钮被撞 ───

  /// 关闭时按钮的位移：往菜单 / 气泡的反方向，约 183ms 到顶（菜单约 17px，几乎不随距离变；气泡按距离），
  /// 约 483ms 回到原位，550ms 停住。
  static Offset triggerRecoil(Offset travel, double elapsed, {double closeStart = 1, bool menu = true}) {
    if (elapsed <= 0 || closeStart <= 0.001) return Offset.zero;
    final pulse = _recoilPulse(elapsed) * closeStart.clamp(0.0, 1.0);
    final denom = travel.distance + (menu ? 8.0 : 75.0);
    return Offset(-17.5 * travel.dx / denom * pulse, -17.5 * travel.dy / denom * pulse);
  }

  /// 关闭时按钮的压缩（约 0.96–1）
  static double triggerImpact(Offset travel, double elapsed, {double closeStart = 1}) {
    if (elapsed <= 0 || closeStart <= 0.001) return 1;
    final pulse = _recoilPulse(elapsed) * closeStart.clamp(0.0, 1.0);
    final d = travel.distance;
    return (1 - (0.025 + 0.015 * d / (d + 75)) * pulse).clamp(0.92, 1.02);
  }

  /// 关闭时按钮重新出现的不透明度：跟着尾巴处那颗圆冒出来（关闭后约 110–230ms）
  static double triggerReturn(double elapsed) => _smoothstep((elapsed - 0.11) / 0.12);

  // ─── 形状 ───

  /// 一帧的外形（以 [DropletFrame.bounds] 左上角为原点）：面板 + 按钮那颗圆 + 两者之间的水滴颈。
  /// 没有那颗圆时就是面板本身。
  static Path outline(DropletFrame f) {
    final o = f.bounds.topLeft;
    final platter = f.platter.shift(-o);
    final r = math.min(f.radius, platter.shortestSide / 2);
    final body = Path()..addRSuperellipse(RSuperellipse.fromRectAndRadius(platter, Radius.circular(r)));
    if (!f.hasBlob) return body;
    final blobC = f.blobCenter - o;
    var shape = Path.combine(
      PathOperation.union,
      body,
      Path()..addOval(Rect.fromCircle(center: blobC, radius: f.blobRadius)),
    );
    // 面板离那颗圆最近的那个圆角当另一颗圆（关闭时面板几乎是圆的，打开时那颗圆多半在面板里面）
    final inner = platter.deflate(r);
    final near = Offset(blobC.dx.clamp(inner.left, inner.right), blobC.dy.clamp(inner.top, inner.bottom));
    final bridge = _metaballBridge(blobC, f.blobRadius, near, r, f.neck);
    if (bridge != null) shape = Path.combine(PathOperation.union, shape, bridge);
    return shape;
  }

  /// 两颗圆之间的 metaball 桥（Hiroyuki Sato 的画法）：两圆间隙在 [reach] 以内才连，越远越细
  static Path? _metaballBridge(Offset c1, double r1, Offset c2, double r2, double reach) {
    if (r1 <= 0.5 || r2 <= 0.5 || reach <= 0.5) return null;
    final d = (c2 - c1).distance;
    final gap = d - r1 - r2;
    if (gap > reach || d <= (r1 - r2).abs() + 0.5) return null;
    final v = lerpDouble(0.55, 0.2, (gap / reach).clamp(0.0, 1.0))!;
    const handleRate = 2.4;
    double u1 = 0, u2 = 0;
    if (d < r1 + r2) {
      u1 = math.acos(((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d)).clamp(-1.0, 1.0));
      u2 = math.acos(((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d)).clamp(-1.0, 1.0));
    }
    final angle1 = (c2 - c1).direction;
    final angle2 = math.acos(((r1 - r2) / d).clamp(-1.0, 1.0));
    final a1a = angle1 + u1 + (angle2 - u1) * v;
    final a1b = angle1 - u1 - (angle2 - u1) * v;
    final a2a = angle1 + math.pi - u2 - (math.pi - u2 - angle2) * v;
    final a2b = angle1 - math.pi + u2 + (math.pi - u2 - angle2) * v;
    Offset at(Offset c, double a, double r) => c + Offset.fromDirection(a, r);
    final p1a = at(c1, a1a, r1), p1b = at(c1, a1b, r1), p2a = at(c2, a2a, r2), p2b = at(c2, a2b, r2);
    var d2 = math.min(v * handleRate, (p1a - p2a).distance / (r1 + r2));
    d2 *= math.min(1.0, d * 2 / (r1 + r2));
    final h1 = at(p1a, a1a - math.pi / 2, r1 * d2);
    final h2 = at(p2a, a2a + math.pi / 2, r2 * d2);
    final h3 = at(p2b, a2b - math.pi / 2, r2 * d2);
    final h4 = at(p1b, a1b + math.pi / 2, r1 * d2);
    return Path()
      ..moveTo(p1a.dx, p1a.dy)
      ..cubicTo(h1.dx, h1.dy, h2.dx, h2.dy, p2a.dx, p2a.dy)
      ..lineTo(p2b.dx, p2b.dy)
      ..cubicTo(h3.dx, h3.dy, h4.dx, h4.dy, p1b.dx, p1b.dy)
      ..close();
  }

  // ─── 内部曲线（数值都来自 liquid_glass_widgets 的实测拟合） ───

  /// 按钮缩成的那颗圆：以按钮中心、短边为直径
  static Rect _core(Rect anchor) {
    final d = math.max(1.0, anchor.shortestSide);
    return Rect.fromCenter(center: anchor.center, width: d, height: d);
  }

  static double _scaleDelta(Size from, Size to) {
    final a = from.width * from.height;
    return a <= 0 ? 1 : math.sqrt(to.width * to.height / a);
  }

  static double _blendAttenuation(double scaleDelta) => scaleDelta <= 3 ? 1 : (3 / scaleDelta).clamp(0.2, 1.0);

  static double _backOutAmplitude(Offset travel) {
    final d = travel.distance;
    return d <= 100 ? 2.5 : (2.5 * 100 / d).clamp(0.7, 2.5);
  }

  /// 菜单在按钮哪一侧对齐：-1 左沿对齐、+1 右沿对齐、0 居中
  static double _alignX(Rect anchor, Rect target) {
    final l = (target.left - anchor.left).abs(), r = (target.right - anchor.right).abs();
    if ((l - r).abs() < 2) return 0;
    return l < r ? -1 : 1;
  }

  /// 打开时面板中心领先的那一下：A·[S(ω24, ζ0.6) − S(ω20, ζ0.9)]，约 110ms 到顶，0.40s 收干净
  static double _openDrift(double t, double height) {
    if (t <= 0) return 0;
    final diff = _step(t, 24, 0.6) - _step(t, 20, 0.9);
    final fade = 1 - _smoothstep((t - 0.26) / 0.14);
    final double peak;
    if (height < 250) {
      final compact = 12 * ((height - 48) / 56).clamp(0.0, 1.0);
      peak = compact + (66 - compact) * ((height - 104) / 146).clamp(0.0, 1.0);
    } else {
      peak = 66 + (56 - 66) * ((height - 250) / 270).clamp(0.0, 1.0);
    }
    return peak * diff / 0.2865 * fade;
  }

  /// 关闭时面板被推离按钮的那一下：A·S(ω20, ζ1)·(1 − S(ω24, ζ1))，约 75–100ms 到顶，300ms 收回
  static double _closeDrift(double t, double height) {
    if (t <= 0) return 0;
    final unit = _step(t, 20, 1) * (1 - _step(t, 24, 1));
    final peak = height < 250
        ? 49 * ((height - 95) / 155).clamp(0.0, 1.0)
        : 49 + (62 - 49) * ((height - 250) / 270).clamp(0.0, 1.0);
    return peak * unit / 0.2047;
  }

  /// 打开时的圆角：前约 140ms 是正圆（短边一半），之后约 145ms 松成面板的圆角（高的面板松得早一点、慢一点）
  static double _openRadius(Size current, Size resting, double finalRadius, double elapsed) {
    final half = math.min(current.width, current.height) / 2;
    final rho0 = (finalRadius / (math.min(resting.width, resting.height) / 2)).clamp(0.0, 1.0);
    final hf = ((resting.height - 250) / 270).clamp(0.0, 1.0);
    final hold = 0.14 * (1 - 0.5 * hf), relax = 0.145 * (1 + 0.24 * hf);
    final k = ((elapsed - 0.02 - hold) / relax).clamp(0.0, 1.0);
    return half * (rho0 + (1 - rho0) * math.pow(1 - k, 1.3)).clamp(0.0, 1.0);
  }

  /// 按钮被撞的脉冲：S(ω17, ζ0.7) − S(ω18, ζ1)，归一到峰值 1（约 183ms）
  static double _recoilPulse(double t) => t <= 0 ? 0 : (_step(t, 17, 0.7) - _step(t, 18, 1)) / 0.139711;

  /// 圆角矩形面板外面一点到它的距离
  static double _gap(Rect platter, double radius, Offset p) {
    final r = math.min(radius, platter.shortestSide / 2);
    final inner = platter.deflate(r);
    final dx = math.max(math.max(inner.left - p.dx, p.dx - inner.right), 0.0);
    final dy = math.max(math.max(inner.top - p.dy, p.dy - inner.bottom), 0.0);
    return math.max(0.0, math.sqrt(dx * dx + dy * dy) - r);
  }

  static Offset _keepInside(Offset center, Size size, Rect core, Rect allowed) {
    final minL = math.min(core.left, allowed.left), maxR = math.max(core.right, allowed.right);
    final minT = math.min(core.top, allowed.top), maxB = math.max(core.bottom, allowed.bottom);
    final x = center.dx.clamp(minL + size.width / 2, math.max(minL + size.width / 2, maxR - size.width / 2));
    final y = center.dy.clamp(minT + size.height / 2, math.max(minT + size.height / 2, maxB - size.height / 2));
    return Offset(x.toDouble(), y.toDouble());
  }

  /// 二阶系统从 0 到 1 的阶跃响应（初速 0）
  static double _step(double t, double w0, double zeta) {
    if (t <= 0) return 0;
    if (zeta < 1 - 1e-6) {
      final r = zeta * w0, w = w0 * math.sqrt(1 - zeta * zeta);
      return 1 + math.exp(-r * t) * (-math.cos(w * t) - r / w * math.sin(w * t));
    }
    if (zeta > 1 + 1e-6) {
      final s = math.sqrt(zeta * zeta - 1);
      final r1 = -w0 * (zeta - s), r2 = -w0 * (zeta + s);
      final c2 = r1 / (r2 - r1), c1 = -1 - c2;
      return 1 + c1 * math.exp(r1 * t) + c2 * math.exp(r2 * t);
    }
    return 1 - (1 + w0 * t) * math.exp(-w0 * t);
  }

  static double _smoothstep(double x) {
    final c = x.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }
}

class _BackOut extends Curve {
  const _BackOut(this.amplitude);
  final double amplitude;

  @override
  double transformInternal(double t) {
    final s = t - 1;
    return s * s * ((amplitude + 1) * s + amplitude) + 1;
  }
}

/// 驱动变形的时钟：打开 / 关闭各一条弹簧，记着这一段走了多久（曲线里有好几处按时间算）。
class DropletMotion extends ChangeNotifier {
  DropletMotion(TickerProvider vsync, {bool settled = false}) : raw = settled ? 1 : 0 {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  SpringSimulation? _sim;

  /// 弹簧的值：0 = 按钮，1 = 面板
  double raw;

  /// 这一段（打开或关闭）走了多少秒
  double elapsed = 0;
  bool closing = false;

  /// 关闭那一刻的 [raw]（打开到一半就关时小于 1）
  double closeStart = 1;

  void open() {
    closing = false;
    _start(SpringSimulation(DropletMorph.openSpring, raw, 1, 0));
  }

  void close() {
    if (closing) return;
    closing = true;
    closeStart = raw.clamp(0.0, 1.0);
    _start(SpringSimulation(DropletMorph.closeSpring, raw, 0, 0));
  }

  void _start(SpringSimulation sim) {
    _sim = sim;
    elapsed = 0;
    _ticker
      ..stop()
      ..start();
    notifyListeners();
  }

  void _tick(Duration d) {
    final sim = _sim;
    if (sim == null) return;
    elapsed = d.inMicroseconds / 1e6;
    raw = sim.x(elapsed);
    // 关闭在面板化完之后就停（弹簧尾巴的小回摆不用画）
    if (sim.isDone(elapsed) || (closing && elapsed >= DropletMorph.closeDuration.inMicroseconds / 1e6)) {
      raw = closing ? 0 : 1;
      _sim = null;
      _ticker.stop();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// 画一帧水滴：玻璃（或实色）铺在 [DropletFrame.bounds] 里，内容按 [target] 的尺寸排好、钉在最终位置，
/// 面板只露出它的一部分（剪成面板的圆角）。[blur] = false（低端机）时内容不糊，只淡入淡出。
/// 有按钮那颗圆时玻璃按合并后的外形画（这一小段没有阴影与细边）；只剩面板时照常画圆角玻璃，细边与阴影跟着厚度长出来。
class DropletSurface extends StatelessWidget {
  const DropletSurface({
    super.key,
    required this.frame,
    required this.target,
    required this.child,
    this.glassStyle,
    this.glassRim,
    this.shadows = const [],
    this.color,
    this.shadowColor = const Color(0x29000000),
    this.blur = true,
  });

  final DropletFrame frame;
  final Rect target;
  final Widget child;

  /// 玻璃（有就画玻璃，否则画实色 [color]）
  final LiquidGlassStyle? glassStyle;
  final LiquidGlassRim? glassRim;
  final List<BoxShadow> shadows;
  final Color? color;

  /// 实色面板的阴影色（满厚度时）
  final Color shadowColor;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final f = frame;
    final bounds = f.bounds;
    final platter = f.platter.shift(-bounds.topLeft);
    final radius = math.min(f.radius, platter.shortestSide / 2);

    Widget content = OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: target.width,
      maxWidth: target.width,
      minHeight: target.height,
      maxHeight: target.height,
      child: Transform.translate(offset: target.topLeft - f.platter.topLeft, child: child),
    );
    final sigma = blur ? f.contentBlur : 0.0;
    // 模糊层一直在树上（只开关）：插拔它会让里面的内容整棵重挂、每帧重画
    content = ImageFiltered(
      enabled: sigma > 0.3,
      imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: content,
    );
    content = Opacity(opacity: f.contentOpacity, child: content);
    content = Positioned.fromRect(
      rect: platter,
      child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: content),
    );

    final style = glassStyle;
    final Widget surface;
    if (style != null) {
      final outline = f.hasBlob ? DropletMorph.outline(f) : null;
      final edge = f.glass * _smooth((f.depth - 0.25) / 0.35);
      // 关闭最后那一段整块淡掉（只把玻璃参数调到 0 的话折射边还在，按钮上会留一颗小透镜）；
      // 用 LiquidGlassFade 而不是 Opacity：后者把玻璃变成离屏层，读不到背后的画面。层一直在（只改透明度），结构不随动画插拔
      surface = LiquidGlassFade(
        opacity: AlwaysStoppedAnimation(f.glass),
        child: MeowGlassBox(
          style: style,
          radius: BorderRadius.circular(radius),
          outline: outline,
          rim: outline == null ? glassRim?.scale(edge) : null,
          shadows: outline == null ? _scaleShadows(shadows, edge) : const [],
          child: Stack(children: [content]),
        ),
      );
    } else {
      final base = color ?? Colors.white;
      surface = Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DropletFill(
                path: DropletMorph.outline(f),
                color: base.withValues(alpha: base.a * f.glass),
                shadow: shadowColor.withValues(alpha: shadowColor.a * f.depth * f.glass),
              ),
            ),
          ),
          content,
        ],
      );
    }
    return Positioned.fromRect(rect: bounds, child: surface);
  }

  static double _smooth(double x) {
    final c = x.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  static List<BoxShadow> _scaleShadows(List<BoxShadow> shadows, double t) =>
      t >= 1 ? shadows : [for (final s in shadows) s.copyWith(color: s.color.withValues(alpha: s.color.a * t))];
}

class _DropletFill extends CustomPainter {
  _DropletFill({required this.path, required this.color, required this.shadow});
  final Path path;
  final Color color;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    if (shadow.a > 0.005) {
      canvas.drawPath(
        path.shift(const Offset(0, 8)),
        Paint()
          ..color = shadow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DropletFill old) => old.path != path || old.color != color || old.shadow != shadow;
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
    child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _dismissLater, child: const SizedBox.expand()),
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
