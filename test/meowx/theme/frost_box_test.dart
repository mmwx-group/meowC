import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bett_box/meowx/theme/backdrop.dart';
import 'package:bett_box/meowx/theme/card_surface.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: meowThemeData(brightness: Brightness.light, look: const MeowLook(style: MeowThemeStyle.glass)),
  home: Scaffold(body: child),
);

class _CountingPainter extends CustomPainter {
  _CountingPainter(this.onPaint);
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) => onPaint();
  @override
  bool shouldRepaint(_CountingPainter old) => false;
}

Future<Uint8List> _pixels(void Function(Canvas) draw, int w, int h) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData();
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  group('玻璃卡片在动画中重画', () {
    testWidgets('跟着动画：和位移同一帧重画、每帧都画，卡片里的内容那层不重录', (tester) async {
      final controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 400));
      addTearDown(controller.dispose);
      var contentPaints = 0;
      await tester.pumpWidget(_app(MeowFrostFollow(
        animations: [controller],
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, child) => Transform.translate(offset: Offset(controller.value * 120, 0), child: child),
          child: RepaintBoundary(
            child: Center(
              child: SizedBox(
                width: 200,
                height: 100,
                child: MeowFrostBox(
                  radius: BorderRadius.circular(16),
                  child: CustomPaint(painter: _CountingPainter(() => contentPaints++), child: const SizedBox.expand()),
                ),
              ),
            ),
          ),
        ),
      )));
      await tester.pump();
      final box = tester.renderObject(find.byType(MeowFrostBox));
      controller.forward();
      await tester.pump();
      final paints = MeowFrostBox.debugPaintCount, content = contentPaints;
      for (var i = 1; i <= 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(MeowFrostBox.debugPaintCount, paints + i, reason: '第 $i 帧：卡片底当帧重画');
        expect(box.debugNeedsPaint, isFalse, reason: '第 $i 帧画完没有遗留的重画（以前要等下一帧补）');
      }
      expect(contentPaints, content, reason: '卡片里的内容是单独一层，挪位置不重录');
      await tester.pumpAndSettle();
    });

    testWidgets('叫醒只叫屏幕上的：隐藏页里的卡片不画', (tester) async {
      await tester.pumpWidget(_app(Column(
        children: [
          SizedBox(width: 120, height: 60, child: MeowFrostBox(radius: BorderRadius.circular(12))),
          Offstage(child: SizedBox(width: 120, height: 60, child: MeowFrostBox(radius: BorderRadius.circular(12)))),
        ],
      )));
      await tester.pump();
      final paints = MeowFrostBox.debugPaintCount;
      MeowFrostBox.markAllMoved();
      await tester.pump();
      expect(MeowFrostBox.debugPaintCount, paints + 1);
    });
  });

  group('玻璃卡片的投影（九宫格图）', () {
    for (final dpr in [1.0, 2.0]) {
      test('与现算的两层模糊一致：像素比 $dpr', () async {
        const card = Rect.fromLTWH(60, 50, 220, 90);
        const r = 18.0;
        final color = MeowFrostStyle.drop(false, 330);
        final w = (340 * dpr).round(), h = (200 * dpr).round();
        final nine = await _pixels((c) {
          c.scale(dpr);
          MeowFrostBox.debugPaintShadow(c, card, r, color, dpr);
        }, w, h);
        final direct = await _pixels((c) {
          c.scale(dpr);
          final rr = RRect.fromRectAndRadius(card, const Radius.circular(r));
          c.drawRRect(
            rr.shift(const Offset(0, MeowFrostStyle.dropDy)),
            Paint()
              ..color = color
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, Shadow.convertRadiusToSigma(MeowFrostStyle.dropBlur / 2)),
          );
          c.drawRRect(
            rr.shift(const Offset(0, 1)),
            Paint()
              ..color = color
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
          );
        }, w, h);
        var worst = 0, over = 0;
        // 卡片里面会被不透明的卡片底盖住，只比露在外面的投影
        final inside = card.deflate(0.5);
        for (var i = 0; i < nine.length; i++) {
          final p = i ~/ 4;
          if (inside.contains(Offset(p % w / dpr, p ~/ w / dpr))) continue;
          final d = (nine[i] - direct[i]).abs();
          if (d > worst) worst = d;
          if (d > 2) over++;
        }
        // 1.5 倍画的图贴到 2 倍屏上，卡片底边那条 1dp 的贴边小影略软一点（透明度 16% 的影上差几个色阶，看不出来）
        expect(worst, lessThanOrEqualTo(6), reason: '最大差 $worst');
        expect(over / nine.length, lessThan(0.01), reason: '差超过 2 个色阶的分量占比');
      });
    }
  });
}
