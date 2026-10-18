import 'package:bett_box/meowx/pages/proxies/group_reveal.dart';
import 'package:bett_box/meowx/theme/morph_menu.dart';
import 'package:bett_box/meowx/theme/motion.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 动画每帧只该动图层（位移 / 透明度 / 被隔开的那一小块），不该连带重画旁边的大块内容。
/// 判断办法：一个 RepaintBoundary 重画一次就换一张新的 PictureLayer；几帧之间还是同一张 = 这几帧没重画它。

/// 数自己被画了几次的方块。
class _PaintCounter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF808080));
  }

  @override
  bool shouldRepaint(_PaintCounter old) => false;
}

/// [finder]（一个 RepaintBoundary）自己画的那张图（它图层下的第一张 PictureLayer）。
PictureLayer? _picture(WidgetTester tester, Finder finder) {
  final boundary = tester.renderObject(finder) as RenderRepaintBoundary;
  Layer? layer = boundary.debugLayer!.firstChild;
  while (layer != null && layer is! PictureLayer) {
    layer = layer.nextSibling;
  }
  return layer as PictureLayer?;
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('节点卡错峰出现：每帧只改底色遮罩与位移（不开透明图层），卡片内容只画一次', (tester) async {
    final reveal = GroupReveal(vsync: const TestVSync(), count: 3, from: 0);
    addTearDown(reveal.dispose);
    final painters = [for (var i = 0; i < 3; i++) _PaintCounter()];
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            for (final (i, p) in painters.indexed)
              StaggeredItem(
                reveal: reveal,
                index: i,
                child: CustomPaint(key: ValueKey('cell$i'), painter: p, size: const Size(100, 40)),
              ),
          ],
        ),
      ),
    );
    reveal.open(() {});
    final total = Stagger.inTotal(3);
    for (var ms = 16; ms < total; ms += 16) {
      await tester.pump(const Duration(milliseconds: 16));
      // 轨迹照旧：位移取自 Stagger；淡入是盖一层底色，不开透明图层（Opacity 每帧一次离屏合成）
      final expected = Stagger.itemIn(1, reveal.clock.value * total);
      final shift = tester.widget<Transform>(
        find.ancestor(of: find.byKey(const ValueKey('cell1')), matching: find.byType(Transform)).first,
      );
      expect(shift.transform.getTranslation().y, closeTo(expected.dy, 1e-9));
      expect(find.ancestor(of: find.byKey(const ValueKey('cell1')), matching: find.byType(Opacity)), findsNothing);
    }
    await tester.pumpAndSettle();
    // 每张卡从开始出现（透明度离开 0）到播完只画一次
    for (final p in painters) {
      expect(p.paints, 1);
    }
  });

  testWidgets('菜单变形：面板每帧变尺寸，菜单项不跟着重画', (tester) async {
    late BuildContext anchor;
    await tester.pumpWidget(
      _app(
        Align(
          alignment: Alignment.topLeft,
          child: Builder(
            builder: (context) {
              anchor = context;
              return const SizedBox(width: 120, height: 40);
            },
          ),
        ),
      ),
    );
    showMeowMenu<int>(
      anchor,
      entries: const [MeowMenuItem(1, '甲', checked: true), MeowMenuItem(2, '乙'), MeowMenuItem(3, '丙')],
    );
    await tester.pump();
    // 菜单项都已淡入（之后透明度不再变），面板的弹簧还在走
    await tester.pump(Duration(milliseconds: MeowMotion.menuItemsTotal(3) + 16));
    final item = find.ancestor(of: find.text('乙'), matching: find.byType(RepaintBoundary)).first;
    final size0 = tester.getSize(find.ancestor(of: item, matching: find.byType(ClipRRect)).first);
    final picture = _picture(tester, item);
    expect(picture, isNotNull);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final size1 = tester.getSize(find.ancestor(of: item, matching: find.byType(ClipRRect)).first);
    expect(size1, isNot(size0), reason: '这几帧面板仍在变形');
    expect(_picture(tester, item), same(picture));
    await tester.pumpAndSettle();
  });

  // 电源键外面那层 Opacity（不可用时半透明）不透明度非零时本身就是一层，液面的重绘已经被它隔开；这里守住这一点
  testWidgets('电源键连接中：液面每帧动，外面的页面不重画', (tester) async {
    const page = ValueKey('page');
    Widget build({required bool busy}) => _app(
      RepaintBoundary(
        key: page,
        child: Column(
          children: [
            const Text('首页上的别的内容'),
            MeowPowerButton(on: false, busy: busy, onTap: () {}),
          ],
        ),
      ),
    );
    await tester.pumpWidget(build(busy: false));
    await tester.pumpWidget(build(busy: true));
    await tester.pump(const Duration(milliseconds: 16));
    final picture = _picture(tester, find.byKey(page));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_picture(tester, find.byKey(page)), same(picture));
    await tester.pumpWidget(_app(const SizedBox()));
  });

  testWidgets('分段滑块弹簧：滑块每帧重绘，外面的页面不重画', (tester) async {
    const page = ValueKey('page');
    Widget build(int v) => _app(
      RepaintBoundary(
        key: page,
        child: Column(
          children: [
            const Text('首页上的别的内容'),
            MeowSegment<int>(items: const [(0, '规则'), (1, '全局'), (2, '直连')], value: v, onChanged: (_) {}),
          ],
        ),
      ),
    );
    await tester.pumpWidget(build(0));
    await tester.pumpWidget(build(2));
    // 颜色渐变（220ms）走完以后弹簧还在晃
    await tester.pump(MeowMotion.colorFade + const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final picture = _picture(tester, find.byKey(page));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_picture(tester, find.byKey(page)), same(picture));
    await tester.pumpAndSettle();
  });
}
