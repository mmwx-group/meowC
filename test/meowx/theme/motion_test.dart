import 'package:bett_box/meowx/pages/proxies/group_reveal.dart';
import 'package:bett_box/meowx/theme/morph_menu.dart';
import 'package:bett_box/meowx/theme/motion.dart';
import 'package:bett_box/meowx/theme/sliver_reveal.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';

/// 包一层 MaterialApp，[reduce] = 系统「移除动画」。
Widget _app(Widget child, {bool reduce = false}) => MaterialApp(
  builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduce), child: c!),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('弹簧参数', () {
    test('三档与预览一致（质量 1）', () {
      expect((MeowMotion.soft.mass, MeowMotion.soft.stiffness, MeowMotion.soft.damping), (1.0, 170.0, 22.0));
      expect((MeowMotion.bouncy.mass, MeowMotion.bouncy.stiffness, MeowMotion.bouncy.damping), (1.0, 260.0, 16.0));
      expect((MeowMotion.snap.mass, MeowMotion.snap.stiffness, MeowMotion.snap.damping), (1.0, 400.0, 30.0));
    });

    testWidgets('移除动画时直接到终态，不起动画', (tester) async {
      final c = AnimationController.unbounded(vsync: const TestVSync());
      addTearDown(c.dispose);
      MeowMotion.spring(c, 1, MeowMotion.bouncy, reduce: true);
      expect(c.value, 1);
      expect(c.isAnimating, isFalse);
    });

    testWidgets('不移除动画时：soft 微回弹、bouncy 明显越过终点，最后都停在终点', (tester) async {
      double peak(SpringDescription s) {
        final sim = SpringSimulation(s, 0, 1, 0);
        var max = 0.0;
        for (var t = 0.0; t < 2; t += 0.004) {
          if (sim.x(t) > max) max = sim.x(t);
        }
        expect(sim.x(3), closeTo(1, 1e-3));
        return max;
      }

      expect(peak(MeowMotion.soft), allOf(greaterThan(1), lessThan(1.02)));
      expect(peak(MeowMotion.bouncy), greaterThan(1.1));
      expect(peak(MeowMotion.snap), lessThan(1.04));
    });
  });

  group('代理组错峰', () {
    test('展开：延迟 40ms + 序号 × 25ms；第 13 张与第 12 张同时出现，之后的也一样', () {
      expect(Stagger.inStart(0), 40);
      expect(Stagger.inStart(1), 65);
      expect(Stagger.inStart(11), 40 + 11 * 25);
      expect(Stagger.inStart(12), Stagger.inStart(11));
      expect(Stagger.inStart(299), Stagger.inStart(11));
      // 300 个节点的组和 12 个的一样长
      expect(Stagger.inTotal(300), Stagger.inTotal(12));
      expect(Stagger.inTotal(12), 40 + 11 * 25 + 320);
      expect(Stagger.inTotal(3), 40 + 2 * 25 + 320);
    });

    test('展开中每张卡：透明度 0→1、位移 10→0', () {
      expect(Stagger.itemIn(0, 0), (opacity: 0.0, dy: 10.0));
      expect(Stagger.itemIn(0, 40 + 320), (opacity: 1.0, dy: 0.0));
      final mid = Stagger.itemIn(0, 40 + 160);
      expect(mid.opacity, inExclusiveRange(0, 1));
      expect(Stagger.itemIn(12, 500), Stagger.itemIn(11, 500));
    });

    test('收起：倒序，每张间隔 15ms；12 张以后的与第 12 张同时最先走', () {
      expect(Stagger.outStart(11, 20), 0);
      expect(Stagger.outStart(19, 20), 0);
      expect(Stagger.outStart(10, 20), 15);
      expect(Stagger.outStart(0, 20), 11 * 15);
      expect(Stagger.outStart(2, 3), 0);
      expect(Stagger.outStart(0, 3), 30);
      expect(Stagger.outTotal(20), 11 * 15 + 140);
      expect(Stagger.itemOut(0, 3, 0), (opacity: 1.0, dy: 0.0));
      expect(Stagger.itemOut(0, 3, 30 + 140), (opacity: 0.0, dy: 6.0));
    });

    testWidgets('GroupReveal：展开时高度弹到 1、卡片按时序出现；收起后高度回 0，播完回调', (tester) async {
      final r = GroupReveal(vsync: const TestVSync(), count: 30, from: 0);
      addTearDown(r.dispose);
      var opened = false;
      r.open(() => opened = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(r.item(0).opacity, greaterThan(0));
      expect(r.item(11).opacity, 0);
      expect(r.item(12).opacity, r.item(11).opacity);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(opened, isTrue);
      expect(r.height.value, closeTo(1, 1e-3));
      expect(r.item(29).opacity, 1);

      var closed = false;
      r.close(() => closed = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // 前 60ms 高度不动，最后几张先淡
      expect(r.height.value, closeTo(1, 1e-6));
      expect(r.item(29).opacity, lessThan(1));
      expect(r.item(0).opacity, 1);
      await tester.pump(const Duration(milliseconds: 400));
      expect(closed, isTrue);
      expect(r.height.value, 0);
    });
  });

  group('电源键液面', () {
    test('1.2s 注到七成，再 6s 涨到 0.92 停住', () {
      expect(pourLevel(0, Duration.zero), 0);
      expect(pourLevel(0, const Duration(milliseconds: 600)), inExclusiveRange(0.35, 0.7));
      expect(pourLevel(0, const Duration(milliseconds: 1200)), closeTo(0.7, 1e-9));
      expect(pourLevel(0, const Duration(milliseconds: 4200)), closeTo(0.81, 1e-9));
      expect(pourLevel(0, const Duration(milliseconds: 7200)), closeTo(0.92, 1e-9));
      expect(pourLevel(0, const Duration(seconds: 60)), closeTo(0.92, 1e-9));
      // 从半满接着注不会先掉下去
      expect(pourLevel(0.4, Duration.zero), 0.4);
      expect(PourSimulation(0).isDone(7.3), isTrue);
      expect(PourSimulation(0).isDone(7.0), isFalse);
    });

    testWidgets('一出现就是已连接：直接满、不重放（没有在跑的动画）', (tester) async {
      await tester.pumpWidget(_app(MeowPowerButton(on: true, onTap: () {})));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('连接中 → 已连接：液面 / 涟漪 / 图标在动；移除动画时直接终态', (tester) async {
      Widget button(bool on, bool busy, {bool reduce = false}) =>
          _app(MeowPowerButton(on: on, busy: busy, onTap: () {}), reduce: reduce);
      await tester.pumpWidget(button(false, true));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(button(true, false));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      await tester.pumpWidget(button(false, false));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();

      await tester.pumpWidget(button(false, true, reduce: true));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(button(true, false, reduce: true));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('分段滑块', () {
    testWidgets('换段时滑块弹过去；移除动画时直接到位', (tester) async {
      Widget seg(int v, {bool reduce = false}) => _app(
        SizedBox(
          width: 300,
          child: MeowSegment<int>(items: const [(0, '规则'), (1, '全局'), (2, '直连')], value: v, onChanged: (_) {}),
        ),
        reduce: reduce,
      );
      await tester.pumpWidget(seg(0));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(seg(2));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      await tester.pumpWidget(seg(1, reduce: true));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('弹出菜单', () {
    test('落点：从按钮顶边往下；下面放不下往上长；左右收进屏幕', () {
      const screen = Size(400, 800);
      const safe = EdgeInsets.only(top: 24, bottom: 20);
      final below = meowMenuRect(
        anchor: const Rect.fromLTWH(20, 100, 120, 40),
        contentHeight: 200,
        width: 200,
        alignEnd: false,
        screen: screen,
        safe: safe,
      );
      expect(below, const Rect.fromLTWH(20, 100, 200, 200));

      final up = meowMenuRect(
        anchor: const Rect.fromLTWH(300, 700, 80, 40),
        contentHeight: 200,
        width: 200,
        alignEnd: true,
        screen: screen,
        safe: safe,
      );
      expect(up, const Rect.fromLTWH(180, 540, 200, 200));

      // 太宽 / 太靠右：收进屏幕；太高：截到安全区内（内容滚动）
      final clamped = meowMenuRect(
        anchor: const Rect.fromLTWH(380, 300, 10, 10),
        contentHeight: 2000,
        width: 500,
        alignEnd: false,
        screen: screen,
        safe: safe,
      );
      expect(clamped.left, 8);
      expect(clamped.right, 392);
      expect(clamped.top, 24 + 8);
      expect(clamped.bottom, 800 - 20 - 8);
    });

    test('菜单项淡入：延迟 140ms + 序号 × 18ms，前 12 项错峰', () {
      expect(MeowMotion.menuItemIn(0, 140), 0);
      expect(MeowMotion.menuItemIn(0, 340), 1);
      expect(MeowMotion.menuItemIn(1, 158), 0);
      expect(MeowMotion.menuItemIn(20, 400), MeowMotion.menuItemIn(11, 400));
      expect(MeowMotion.menuItemsTotal(3), 140 + 2 * 18 + 200);
    });

    Future<void> openAndPick(WidgetTester tester, {required bool reduce}) async {
      String? picked;
      await tester.pumpWidget(
        _app(
          MeowMenuButton<String>(
            entries: () => const [
              MeowMenuCaption('布局'),
              MeowMenuItem('a', '列表', checked: true),
              MeowMenuItem('b', '单组'),
              MeowMenuDivider(),
              MeowMenuItem('c', '大卡'),
            ],
            onSelected: (v) => picked = v,
            builder: (_, open) => TextButton(onPressed: open, child: const Text('视图')),
          ),
          reduce: reduce,
        ),
      );
      await tester.tap(find.text('视图'));
      await tester.pump();
      if (!reduce) await tester.pumpAndSettle();
      expect(find.text('单组'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));   // 每项都有勾，只是没选中的透明

      await tester.tap(find.text('单组'));
      await tester.pump();
      if (!reduce) {
        // 选中块滑过去，220ms 后才关
        await tester.pump(const Duration(milliseconds: 200));
        expect(picked, isNull);
      }
      await tester.pumpAndSettle();
      expect(picked, 'b');
      expect(find.text('单组'), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    }

    testWidgets('点选一项：滑块过去、220ms 后关闭并回传值', (tester) => openAndPick(tester, reduce: false));
    testWidgets('移除动画时同样能选、立刻关', (tester) => openAndPick(tester, reduce: true));

    testWidgets('点菜单外面关闭，不回传值；按钮淡回', (tester) async {
      var picked = false;
      await tester.pumpWidget(
        _app(
          MeowMenuButton<int>(
            entries: () => const [MeowMenuItem(1, '一')],
            onSelected: (_) => picked = true,
            builder: (_, open) => TextButton(onPressed: open, child: const Text('开')),
          ),
        ),
      );
      await tester.tap(find.text('开'));
      await tester.pumpAndSettle();
      expect(find.text('一'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('一'), findsNothing);
      expect(picked, isFalse);
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: find.text('开'), matching: find.byType(FadeTransition)).first,
      );
      expect(fade.opacity.value, 1);
    });
  });

  testWidgets('SliverReveal：按比例报长度，比例 1 时原样透传', (tester) async {
    Widget list(double f) => MaterialApp(
      home: CustomScrollView(
        slivers: [
          SliverReveal(
            factor: f,
            sliver: const SliverToBoxAdapter(child: SizedBox(height: 200)),
          ),
        ],
      ),
    );
    await tester.pumpWidget(list(0.25));
    final render = tester.renderObject<RenderSliverReveal>(find.byType(SliverReveal));
    expect(render.geometry!.scrollExtent, 50);
    expect(render.geometry!.paintExtent, 50);
    await tester.pumpWidget(list(1));
    expect(render.geometry!.scrollExtent, 200);
    await tester.pumpWidget(list(0));
    expect(render.geometry!.visible, isFalse);
  });
}
