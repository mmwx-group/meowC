import 'dart:math' as math;

import 'package:bett_box/meowx/theme/droplet_morph.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// 水滴变形的曲线（照 iOS 27 原生菜单的逐帧实测，见 DropletMorph 文件头）。
void main() {
  // 右上角一颗 44 的按钮，菜单 220 × 250 从按钮顶边往下、右沿对齐
  const anchor = Rect.fromLTWH(300, 60, 44, 44);
  const target = Rect.fromLTWH(124, 60, 220, 250);
  const radius = 16.0;
  // 同样大小、但整个在按钮下方的菜单（不盖按钮）：那段「先荡出去再收回」的位移只对它还完整保留
  const below = Rect.fromLTWH(124, 112, 220, 250);

  DropletFrame open(double raw, double t) =>
      DropletMorph.open(anchor: anchor, target: target, finalRadius: radius, raw: raw, elapsed: t);
  DropletFrame close(double raw, double t) =>
      DropletMorph.close(anchor: anchor, target: target, finalRadius: radius, raw: raw, elapsed: t);

  group('盖着按钮的气泡全程不离开按钮（以前荡出去时整块飘到列表中间、按钮又露出来，真机上看着闪一下）', () {
    test('打开：每一帧面板都盖着按钮中心，起点是按钮、终点是气泡', () {
      for (var ms = 0; ms <= 600; ms += 8) {
        final t = ms / 1000;
        // raw 用一条粗略的弹簧进度（0 → 1），连同过冲前后的各种组合都要成立
        for (final raw in [math.min(1.0, t / 0.25), math.min(1.0, t / 0.12), 1.0]) {
          final f = open(raw, t);
          expect(f.platter.inflate(0.01).contains(anchor.center), isTrue, reason: 't=$t raw=$raw platter=${f.platter}');
        }
      }
      expect(open(0, 0).platter, anchor);
      expect(open(1, 0.6).platter.center.dy, closeTo(target.center.dy, 0.5));
    });

    test('关闭：每一帧面板都盖着（被撞开的）按钮中心', () {
      for (var ms = 0; ms <= 400; ms += 8) {
        final t = ms / 1000;
        for (final raw in [math.max(0.0, 1 - t / 0.2), math.max(0.0, 1 - t / 0.1), 0.5]) {
          final f = DropletMorph.close(anchor: anchor, target: target, finalRadius: radius, raw: raw, elapsed: t, menu: false);
          final kick = DropletMorph.triggerRecoil(target.center - anchor.center, t, menu: false);
          expect(f.platter.inflate(0.01).contains(anchor.center + kick), isTrue, reason: 't=$t raw=$raw platter=${f.platter}');
        }
      }
    });
  });

  group('打开', () {
    test('第一帧：按钮缩成的那颗圆（短边为直径），按钮那颗圆还在', () {
      final f = open(0, 0);
      expect(f.platter, const Rect.fromLTWH(300, 60, 44, 44));
      expect(f.radius, 22);
      expect(f.blobRadius, 22);
      expect(f.glass, 1, reason: '一出来就是玻璃');
      expect(f.contentOpacity, 0);
    });

    test('按钮那颗圆在前 40% 缩没', () {
      expect(open(0.2, 0.04).blobRadius, closeTo(11, 1e-9));
      expect(open(0.4, 0.09).hasBlob, isFalse);
    });

    test('不盖按钮的菜单：面板中心先往远离按钮的方向冲出去（约 110ms 到顶、中等菜单约 66px），0.40s 收干净', () {
      double lead(double t) =>
          DropletMorph.open(anchor: anchor, target: below, finalRadius: radius, raw: 1, elapsed: t).platter.center.dy -
          below.center.dy;
      final peak = [for (var ms = 60; ms <= 160; ms += 10) lead(ms / 1000)].reduce(math.max);
      expect(peak, inInclusiveRange(55, 70));
      expect(lead(0.11), greaterThan(55));
      expect(lead(0.40).abs(), lessThan(0.5));
    });

    test('圆角：前约 140ms 是正圆，约 300ms 收成面板的圆角', () {
      final early = open(0.9, 0.12);
      expect(early.radius, closeTo(early.platter.shortestSide / 2, 1e-9));
      expect(open(1, 0.31).radius, closeTo(radius, 0.01));
    });

    test('内容：120ms 还看不见，约 240ms 清楚出现', () {
      expect(open(0.7, 0.12).contentOpacity, 0);
      expect(open(0.7, 0.12).contentBlur, 8);
      expect(open(1, 0.25).contentOpacity, 1);
      expect(open(1, 0.25).contentBlur, 0);
    });

    test('安全区：冲出去时不越出给定范围', () {
      const low = Rect.fromLTWH(124, 500, 220, 250);
      final f = DropletMorph.open(
        anchor: const Rect.fromLTWH(300, 500, 44, 44),
        target: low,
        finalRadius: radius,
        raw: 1,
        elapsed: 0.11,
        allowed: const Rect.fromLTRB(8, 40, 400, 760),
      );
      expect(f.platter.bottom, lessThanOrEqualTo(760 + 1e-9));
    });
  });

  group('关闭', () {
    test('起点就是菜单本身', () {
      final f = close(1, 0);
      expect(f.platter, target);
      expect(f.radius, closeTo(radius, 1e-9));
      expect(f.contentOpacity, 1);
      expect(f.glass, 1);
      expect(f.hasBlob, isFalse);
    });

    test('不盖按钮的菜单：以按钮中心为支点等比缩放，同时先被推离按钮', () {
      const target = below;
      final f = DropletMorph.close(anchor: anchor, target: target, finalRadius: radius, raw: 0.5, elapsed: 0.09);
      expect(f.platter.width, closeTo(220 * 0.6, 0.5));
      // 只按支点缩放时的中心
      final fy = (anchor.center.dy - target.top) / target.height;
      final scaledCenterY = anchor.center.dy - fy * f.platter.height + f.platter.height / 2;
      expect(f.platter.center.dy - scaledCenterY, greaterThan(20), reason: '被推离按钮（菜单在下方 = 往下）');
      expect(f.contentBlur, 8, reason: '内容立刻糊掉');
      expect(f.contentOpacity, closeTo(0.5, 1e-9));
    });

    test('越缩越圆，最后是一条比按钮还细的尾巴流回按钮，玻璃化掉', () {
      final mid = close(0.3, 0.13);
      expect(mid.radius / (mid.platter.shortestSide / 2), greaterThan(0.85));
      final end = close(0, 0.3);
      expect(end.platter.width, lessThan(anchor.width));
      // 尾巴收向按钮——按钮此刻还在被撞的位移上
      final kick = DropletMorph.triggerRecoil(target.center - anchor.center, 0.3);
      expect((end.platter.center.dx - (anchor.center.dx + kick.dx)).abs(), lessThan(1));
      expect(end.glass, 0);
    });

    test('按钮那颗圆：时间到了、面板也够近才冒出来，从 0.45 起', () {
      expect(close(0.6, 0.07).hasBlob, isFalse);
      final f = close(0.1, 0.18);
      expect(f.blobRadius, greaterThanOrEqualTo(22 * 0.45 - 1e-9));
    });
  });

  group('按钮被撞', () {
    const travel = Offset(-88, 125);
    test('菜单：约 183ms 到顶、约 17px、往菜单的反方向；约 483ms 回到原位', () {
      final peak = DropletMorph.triggerRecoil(travel, 0.183);
      expect(peak.distance, inInclusiveRange(16, 17.5));
      expect(peak.dy, lessThan(0));
      expect(peak.dx, greaterThan(0));
      expect(DropletMorph.triggerRecoil(travel, 0.483).distance, lessThan(1));
    });

    test('压缩约 0.96–0.97，开头和停住都是 1', () {
      expect(DropletMorph.triggerImpact(travel, 0.183), inInclusiveRange(0.955, 0.975));
      expect(DropletMorph.triggerImpact(travel, 0), 1);
    });

    test('按钮跟着尾巴冒出来：100ms 还没有，240ms 已经回来', () {
      expect(DropletMorph.triggerReturn(0.10), 0);
      expect(DropletMorph.triggerReturn(0.24), 1);
    });
  });

  group('外形', () {
    test('只有面板时就是面板的圆角矩形', () {
      final f = open(1, 0.4);
      final path = DropletMorph.outline(f);
      expect(path.getBounds().size.width, closeTo(target.width, 0.5));
    });

    test('面板与那颗圆之间：伸手够得着时连成水滴颈，够不着时断开', () {
      const platter = Rect.fromLTWH(100, 200, 40, 40);
      const blob = Offset(120, 160);
      DropletFrame frame(double neck) => DropletFrame(
        platter: platter,
        radius: 20,
        blobCenter: blob,
        blobRadius: 10,
        neck: neck,
        contentOpacity: 0,
        contentBlur: 0,
        glass: 1,
        depth: 0,
      );
      // 两圆间隙 = 60 − 20 − 10 = 30（局部坐标原点在 bounds 左上角 (100, 150)）
      const midpoint = Offset(20, 35);
      expect(DropletMorph.outline(frame(40)).contains(midpoint), isTrue);
      expect(DropletMorph.outline(frame(20)).contains(midpoint), isFalse);
    });
  });

  testWidgets('DropletMotion：打开弹到 1，关闭在 300ms 内落到 0 并停下', (tester) async {
    final m = DropletMotion(const TestVSync());
    addTearDown(m.dispose);
    m.open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(m.raw, inInclusiveRange(0.5, 0.7));
    await tester.pump(const Duration(seconds: 2));
    expect(m.raw, 1);
    m.close();
    expect(m.closeStart, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(m.raw, inInclusiveRange(0.3, 0.5));
    await tester.pump(const Duration(milliseconds: 250));
    expect(m.raw, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
