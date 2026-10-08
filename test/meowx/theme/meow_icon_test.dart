import 'dart:typed_data';

import 'package:bett_box/meowx/pages/me/me_page.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

/// 对照用：同一条路径交给 flutter_svg 画（图标原来的画法，这里把颜色直接写进描边、不套 colorFilter 的离屏层）。
Widget _reference(String d, {required double size, required Color color, double stroke = 1.9}) {
  final hex = (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  return SvgPicture.string(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="$d" fill="none" stroke="#$hex" '
    'stroke-width="$stroke" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    width: size,
    height: size,
  );
}

Future<Uint8List> _pixels(WidgetTester tester, Key key) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// 两张图逐通道比较：最大差值，以及 [a] 里有墨的像素数（防两张空白图互相「一致」）。
(int, int) _compare(Uint8List a, Uint8List b) {
  expect(b.length, a.length);
  var maxDiff = 0, inked = 0;
  for (var i = 0; i < a.length; i++) {
    final diff = (a[i] - b[i]).abs();
    if (diff > maxDiff) maxDiff = diff;
    if (i % 4 == 3 && a[i] > 0) inked++;
  }
  return (maxDiff, inked);
}

Future<void> _pumpPairs(WidgetTester tester, List<(String, Widget, Widget)> pairs) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: Wrap(
          children: [
            for (final (name, expected, actual) in pairs) ...[
              RepaintBoundary(key: ValueKey('expected-$name'), child: expected),
              RepaintBoundary(key: ValueKey('actual-$name'), child: actual),
            ],
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectSame(WidgetTester tester, String name, {String? reason}) async {
  final expected = await _pixels(tester, ValueKey('expected-$name'));
  final actual = await _pixels(tester, ValueKey('actual-$name'));
  final (maxDiff, inked) = _compare(expected, actual);
  expect(inked, greaterThan(0), reason: '$name：对照图是空的 ${reason ?? ''}');
  // 实测逐像素相同；留一点余量给以后引擎 / flutter_svg 升级带来的抗锯齿尾数差
  expect(maxDiff, lessThanOrEqualTo(8), reason: '$name：和 SVG 画出来的不一样 ${reason ?? ''}');
}

/// 1 倍屏、够大的画布：图标给多少就是多少像素，几十个并排也摆得下。
void _useCanvas(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(2400, 2400);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('每个图标直接画出来都和 SVG 的画法逐像素一致（各种实际用到的像素尺寸）', (tester) async {
    _useCanvas(tester);
    final glyphs = <(String, Widget Function(double size, Color color), String d, double stroke)>[
      for (final g in MeowGlyph.values) (g.name, (size, color) => MeowIcon(g, size: size, color: color), g.d, 1.9),
      // 电源键里的那一份描边更粗
      ('power-2.2', (size, color) => MeowIcon(MeowGlyph.power, size: size, color: color, stroke: 2.2), MeowGlyph.power.d, 2.2),
      // 「我的」页入口行自己的图标
      for (final (i, d) in meEntryGlyphPaths.indexed) ('entry-$i', (size, color) => MeowIcon.path(d, size: size, color: color), d, 1.9),
      // 现有图标没用到、以后可能用到的写法：带旋转的椭圆弧、粘在一起写的标志、半径不够要放大的弧
      for (final (i, d) in const [
        'M6 12a7 4 30 1 0 12 0a7 4 30 1 0-12 0',
        'M20 12a8 8 0 11-2.3-5.7',
        'M4 4a3.3 3.3 0 0 1 3.3 3.3A5.7 5.7 0 0 0 13 13',
        'M4 12a1 1 0 0 1 16 0',
      ].indexed)
        ('extra-$i', (size, color) => MeowIcon.path(d, size: size, color: color), d, 1.9),
    ];
    expect(meEntryGlyphPaths, isNotEmpty);
    // 1 倍屏（Windows）上的 12–23，和它们在 2 / 3 倍屏上的像素数；103 ≈ 电源键 34.4dp × 3（缩放比不是整数）
    for (final size in const [12.0, 13.0, 15.0, 16.0, 17.0, 18.0, 20.0, 22.0, 23.0, 34.0, 44.0, 46.0, 51.0, 66.0, 69.0, 103.0]) {
      for (final color in const [Color(0xFF2A2130), Color(0xFFB02E63)]) {
        await _pumpPairs(tester, [
          for (final (name, build, d, stroke) in glyphs)
            (name, _reference(d, size: size, color: color, stroke: stroke), build(size, color)),
        ]);
        for (final (name, _, _, _) in glyphs) {
          await _expectSame(tester, name, reason: '@$size');
        }
      }
    }
  });

  testWidgets('盒子和图标尺寸不一样时等比缩进去并居中（和 SVG 一样）', (tester) async {
    _useCanvas(tester);
    const color = Color(0xFF2A2130);
    Widget boxed(double w, double h, Widget child) => SizedBox(width: w, height: h, child: child);
    await _pumpPairs(tester, [
      for (final (name, w, h) in const [('bigger', 40.0, 40.0), ('wide', 60.0, 24.0), ('tall', 20.0, 48.0)])
        (
          name,
          boxed(w, h, _reference(MeowGlyph.refresh.d, size: 22, color: color)),
          boxed(w, h, const MeowIcon(MeowGlyph.refresh, size: 22, color: color)),
        ),
    ]);
    for (final name in const ['bigger', 'wide', 'tall']) {
      await _expectSame(tester, name);
    }
  });

  testWidgets('themed：尺寸和颜色跟 IconTheme；显式给了的以给的为准', (tester) async {
    _useCanvas(tester);
    const color = Color(0xFFB02E63);
    await _pumpPairs(tester, [
      (
        'themed',
        const MeowIcon(MeowGlyph.nodes, size: 31, color: color),
        const IconTheme(data: IconThemeData(size: 31, color: color), child: MeowIcon.themed(MeowGlyph.nodes)),
      ),
      // 显式给的尺寸 / 颜色优先于 IconTheme
      (
        'explicit',
        const MeowIcon(MeowGlyph.nodes, size: 18, color: color),
        const IconTheme(
          data: IconThemeData(size: 31, color: Color(0xFF000000)),
          child: MeowIcon(MeowGlyph.nodes, size: 18, color: color),
        ),
      ),
    ]);
    await _expectSame(tester, 'themed');
    await _expectSame(tester, 'explicit');
    expect(tester.getSize(find.byType(MeowIcon).at(1)), const Size.square(31));
    expect(tester.getSize(find.byType(MeowIcon).at(3)), const Size.square(18));
  });

  testWidgets('占位大小就是给的尺寸，首帧就有图；读屏语义仍是一张没有文字的图片', (tester) async {
    _useCanvas(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(key: ValueKey('icon'), child: MeowIcon(MeowGlyph.home, size: 40, color: Color(0xFF2A2130))),
        ),
      ),
    );
    // 只 pump 了这一帧，没有等任何异步加载
    expect(tester.getSize(find.byType(MeowIcon)), const Size.square(40));
    final pixels = await _pixels(tester, const ValueKey('icon'));
    expect([for (var i = 3; i < pixels.length; i += 4) pixels[i]].where((a) => a > 0), isNotEmpty);
    expect(tester.getSemantics(find.byType(MeowIcon)), matchesSemantics(isImage: true));
    semantics.dispose();
  });
}
