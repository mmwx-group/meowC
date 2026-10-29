import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bett_box/meowx/app/backdrop_host.dart';
import 'package:bett_box/meowx/theme/backdrop.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 局部对比度垫层（MeowScrimMap）：按每一小格背后的背景算要垫多少，烤进卡片用的预模糊图（2026-10-29）。
void main() {
  // 用户截图里的两种背景：淡紫的天空、暗的山；深色下的亮光斑与暗底
  const sky = Color(0xFFC9C3EE), rock = Color(0xFF3A3446), blob = Color(0xFFD08AA8), night = Color(0xFF16131C);
  // 主题实际算出来的正文 / 次级字（自己的插画背景）
  MeowTokens tokens(Brightness b, double frost) =>
      MeowTokens.resolve(b, MeowLook(style: MeowThemeStyle.glass, bgPattern: MeowBgPattern.art, glassFrost: frost, artImage: 'x'));
  List<(Color, double)> texts(MeowTokens t, double frost) => [(t.t1, MeowScrimMap.bodyTarget(frost)), (t.t2, 4.5)];

  Color lightSurface(Color bg, double s, double fill) => Color.lerp(bg, Colors.white, 1 - (1 - s) * (1 - fill))!;
  Color darkSurface(Color bg, double s, double fill) =>
      Color.alphaBlend(Colors.white.withValues(alpha: fill), Color.lerp(bg, Colors.black, s)!);

  group('MeowScrimMap', () {
    test('正文要求：磨砂 ≥ 0.5 是 7，往透明走降到 4.5 为止（以前降到不保证）', () {
      expect(MeowScrimMap.bodyTarget(0.5), 7);
      expect(MeowScrimMap.bodyTarget(0.9), 7);
      expect(MeowScrimMap.bodyTarget(0.25), closeTo(5.75, 1e-9));
      expect(MeowScrimMap.bodyTarget(0), 4.5);
    });

    test('浅色：压在暗处（山）的垫白到正文、次级字都够；亮处（天空）不垫。磨砂 0（填充几乎没有）也保底', () {
      for (final frost in [0.0, 0.5]) {
        final t = tokens(Brightness.light, frost);
        final fill = t.backdrop!.fill.bottom;
        final want = texts(t, frost);
        expect(MeowScrimMap.scrimAt(sky, fillAlpha: fill, dark: false, texts: want), 0, reason: 'f=$frost');
        final s = MeowScrimMap.scrimAt(rock, fillAlpha: fill, dark: false, texts: want);
        expect(s, greaterThan(0));
        final surface = lightSurface(rock, s, fill);
        expect(MeowTokens.contrast(t.t1, surface), greaterThanOrEqualTo(MeowScrimMap.bodyTarget(frost) - 1e-6));
        expect(MeowTokens.contrast(t.t2, surface), greaterThanOrEqualTo(4.5 - 1e-6));
        // 只垫到够：再少一点就不够（二分到 1/1024）
        final less = lightSurface(rock, s - 0.01, fill);
        expect(want.any((x) => MeowTokens.contrast(x.$1, less) < x.$2), isTrue);
      }
    });

    test('深色：压在亮处（光斑）的垫黑；暗处不垫（以前整套卡片都按最亮那一点垫，暗处也被压黑）', () {
      final t = tokens(Brightness.dark, 0.5);
      final fill = t.backdrop!.fill.top;
      final want = texts(t, 0.5);
      expect(MeowScrimMap.scrimAt(night, fillAlpha: fill, dark: true, texts: want), 0);
      final s = MeowScrimMap.scrimAt(blob, fillAlpha: fill, dark: true, texts: want);
      expect(s, greaterThan(0));
      expect(MeowTokens.contrast(t.t1, darkSurface(blob, s, fill)), greaterThanOrEqualTo(7 - 1e-6));
      expect(MeowTokens.contrast(t.t2, darkSurface(blob, s, fill)), greaterThanOrEqualTo(4.5 - 1e-6));
    });

    test('上限 0.85：纯黑上的深色字到顶也只垫到白的总覆盖 0.85', () {
      final s = MeowScrimMap.scrimAt(Colors.black, fillAlpha: 0.02, dark: false, texts: const [(Color(0xFF000000), 21.0)]);
      expect(1 - (1 - s) * (1 - 0.02), closeTo(0.85, 1e-9));
      expect(MeowScrimMap.scrimAt(Colors.white, fillAlpha: 0.1, dark: true, texts: const [(Colors.white, 21.0)]), 0.85);
    });

    test('网格：每格按自己的背景算，再取 3×3 邻格最大；遮罩是黑色 + 不透明度', () {
      const w = 5, h = 4;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        final c = i == 2 * w + 2 ? rock : sky; // 正中间一格是山
        rgba
          ..[i * 4] = (c.r * 255).round()
          ..[i * 4 + 1] = (c.g * 255).round()
          ..[i * 4 + 2] = (c.b * 255).round()
          ..[i * 4 + 3] = 255;
      }
      final want = texts(tokens(Brightness.light, 0), 0);
      final grid = MeowScrimMap.build(rgba, w, h, fillAlpha: 0.02, dark: false, texts: want);
      final need = MeowScrimMap.scrimAt(rock, fillAlpha: 0.02, dark: false, texts: want);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final near = (x - 2).abs() <= 1 && (y - 2).abs() <= 1;
          expect(grid[y * w + x], closeTo(near ? need : 0, 1e-6), reason: '($x, $y)');
        }
      }
      final mask = MeowScrimMap.mask(grid);
      expect(mask.length, w * h * 4);
      expect([mask[(2 * w + 2) * 4], mask[(2 * w + 2) * 4 + 1], mask[(2 * w + 2) * 4 + 2]], [0, 0, 0]);
      expect(mask[(2 * w + 2) * 4 + 3], (need * 255).round());
      expect(mask[3], 0);
    });
  });

  testWidgets('宿主：卡片用的预模糊图叠好局部垫层（localScrim），每一处正文都 ≥ 7（深色光斑：亮的光斑处垫黑）', (tester) async {
    const look = MeowLook(style: MeowThemeStyle.glass, bgPattern: MeowBgPattern.blobs);
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    MeowBackdropImages? images;
    await tester.pumpWidget(MaterialApp(
      theme: meowThemeData(brightness: Brightness.dark, look: look),
      home: MeowBackdropHost(
        child: Builder(builder: (context) {
          images = MeowBackdropScope.of(context);
          return const SizedBox.expand();
        }),
      ),
    ));
    for (var i = 0; i < 100 && images == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    final got = images!;
    expect(got.localScrim, isTrue);
    final t = MeowTokens.resolve(Brightness.dark, look);
    final spec = t.backdrop!;
    expect(got.frost.width, (360 * got.frostScale).ceil());
    final data = (await tester.runAsync(() => got.frost.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    final px = data.buffer.asUint8List();
    var scrimmed = 0;
    for (var i = 0; i < px.length; i += 4) {
      final c = Color.fromARGB(255, px[i], px[i + 1], px[i + 2]);
      final surface = Color.alphaBlend(Colors.white.withValues(alpha: spec.fill.top), c);
      // 遮罩是每 8dp 一格、双线性放大：留一点余量
      expect(MeowTokens.contrast(t.t1, surface), greaterThanOrEqualTo(6.6), reason: 'pixel ${i ~/ 4}');
      if (MeowTokens.contrast(t.t1, surface) < 8) scrimmed++;
    }
    // 光斑处确实被垫到刚好够（不是整张一律压到很黑）
    expect(scrimmed, greaterThan(0));
  });
}
