import 'package:bett_box/meowx/theme/m3.dart';
import 'package:bett_box/meowx/theme/m3_kit.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: meowThemeData(brightness: Brightness.light),
  home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
);

ColorScheme get _cs => MeowColors.scheme(MeowColors.brandSeed, Brightness.light);

BoxDecoration _decorationAbove(WidgetTester tester, Finder f) => tester
        .widget<AnimatedContainer>(find.ancestor(of: f, matching: find.byType(AnimatedContainer)).first)
        .decoration!
    as BoxDecoration;

/// 按钮组的形状画在 ClipRRect 上（水波跟着裁），底色在里面的 AnimatedContainer 上
BorderRadius? _clipAbove(WidgetTester tester, Finder f) =>
    tester.widget<ClipRRect>(find.ancestor(of: f, matching: find.byType(ClipRRect)).first).borderRadius as BorderRadius?;

void main() {
  testWidgets('连接式按钮组：选中的是主色胶囊，其余首尾外侧大圆角、内侧小圆角；点了回调、点选中的不回调', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _app(
        M3ButtonGroup<String>(
          items: const [('rule', '规则'), ('global', '全局'), ('direct', '直连')],
          selected: 'rule',
          onChanged: (v) => picked = v,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rule = _decorationAbove(tester, find.text('规则'));
    final global = _decorationAbove(tester, find.text('全局'));
    final direct = _decorationAbove(tester, find.text('直连'));
    expect(rule.color, _cs.primary);
    expect(_clipAbove(tester, find.text('规则')), BorderRadius.circular(24));
    expect(global.color, _cs.surfaceContainerHighest);
    expect(_clipAbove(tester, find.text('全局')), BorderRadius.circular(MeowShape.s));
    expect(
      _clipAbove(tester, find.text('直连')),
      const BorderRadius.horizontal(left: Radius.circular(MeowShape.s), right: Radius.circular(24)),
    );
    expect(direct.color, _cs.surfaceContainerHighest);

    await tester.tap(find.text('规则'));
    expect(picked, isNull);
    await tester.tap(find.text('直连'));
    expect(picked, 'direct');
  });

  testWidgets('分段清单：首行上大下小、中间四角小、末行上小下大；选中的行四角 28、次色容器底', (tester) async {
    await tester.pumpWidget(
      _app(
        const M3SegmentedList(
          children: [
            M3ListRow(title: 'A'),
            M3ListRow(title: 'B'),
            M3ListRow(title: 'C', selected: true),
            M3ListRow(title: 'D'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_decorationAbove(tester, find.text('A')).borderRadius, MeowShape.segment(0, 4, outer: 24, inner: 6));
    expect(_decorationAbove(tester, find.text('B')).borderRadius, BorderRadius.circular(6));
    expect(_decorationAbove(tester, find.text('D')).borderRadius, MeowShape.segment(3, 4, outer: 24, inner: 6));
    final c = _decorationAbove(tester, find.text('C'));
    expect(c.borderRadius, BorderRadius.circular(MeowShape.xl));
    expect(c.color, _cs.secondaryContainer);
    expect(tester.getTopLeft(find.text('B')).dy - tester.getTopLeft(find.text('A')).dy, greaterThan(40));
  });

  testWidgets('筛选 chip：没选中描边方角，选中次色容器底、圆角 = 半高', (tester) async {
    var on = false;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (_, set) => M3FilterChip(label: '代理', selected: on, onTap: () => set(() => on = !on)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    var d = _decorationAbove(tester, find.text('代理'));
    expect(d.borderRadius, BorderRadius.circular(MeowShape.m));
    expect(d.color, Colors.transparent);
    await tester.tap(find.text('代理'));
    await tester.pumpAndSettle();
    d = _decorationAbove(tester, find.text('代理'));
    expect(d.borderRadius, BorderRadius.circular(18));
    expect(d.color, _cs.secondaryContainer);
  });

  test('饼干形：外沿贴着外接圆，凹处 = 半径 ×（1 − depth）；squareness = 1 是圆角方块（四角比边中点远）', () {
    const size = Size(200, 200);
    final cookie = meowPolarShape(size, lobes: 9, depth: 0.1).getBounds();
    // 0° 是一瓣的顶点（贴着外接圆）；九瓣是奇数，对面 180° 正好是凹处
    expect(cookie.right, closeTo(200, 0.5));
    final path = meowPolarShape(size, lobes: 9, depth: 0.1);
    expect(path.contains(const Offset(100 - 88, 100)), isTrue, reason: '180° 凹处半径 90');
    expect(path.contains(const Offset(100 - 92, 100)), isFalse);
    final square = meowPolarShape(size, lobes: 9, depth: 0.1, squareness: 1);
    expect(square.contains(const Offset(100 + 80, 100 + 80)), isTrue, reason: '对角方向 0.8 半径处在方块里');
    final circleish = meowPolarShape(size, lobes: 9, depth: 0);
    expect(circleish.contains(const Offset(100 + 80, 100 + 80)), isFalse, reason: '圆在对角方向只到 0.707');
  });

  test('电源键形状：八瓣 ↔ 方块全程四重对称；方块边中点 90%、花瓣外沿贴着外接圆', () {
    const size = Size(200, 200);
    const c = Offset(100, 100);
    for (final m in [0.0, 0.3, 0.5, 0.8, 1.0]) {
      final path = meowPowerShape(size, morph: m, depth: 1 - m);
      // 转 90° 的点在不在形状里应当一致（四重对称）
      for (final p in [const Offset(160, 120), const Offset(185, 100), const Offset(170, 170)]) {
        final q = c + Offset(-(p.dy - c.dy), p.dx - c.dx);
        expect(path.contains(p), path.contains(q), reason: 'morph $m 点 $p');
      }
    }
    final square = meowPowerShape(size, morph: 1, depth: 0).getBounds();
    expect(square.right, closeTo(190, 0.5));
    final flower = meowPowerShape(size, morph: 0, depth: 1).getBounds();
    expect(flower.right, closeTo(200, 0.5));
  });

  testWidgets('电源键：没连是浅底 + 主色图标，连上换成主色饼干 + 白图标；忙的时候在转、停下不报错', (tester) async {
    var on = false, busy = false;
    late StateSetter set;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (_, s) {
            set = s;
            return M3PowerButton(on: on, busy: busy, onTap: () {});
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Icon icon() => tester.widget<Icon>(find.byIcon(Icons.power_settings_new_rounded));
    expect(icon().color, _cs.primary);
    expect(find.bySemanticsLabel('连接'), findsOneWidget);

    set(() => busy = true);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.bySemanticsLabel('正在连接'), findsOneWidget);
    set(() {
      busy = false;
      on = true;
    });
    await tester.pumpAndSettle();
    expect(icon().color, _cs.onPrimary);
    expect(find.bySemanticsLabel('断开连接'), findsOneWidget);
  });

  testWidgets('波浪进度条：值变化动画到位，进行中一直动（pumpAndSettle 会超时）、静止时停', (tester) async {
    var animate = false;
    late StateSetter set;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (_, s) {
            set = s;
            return M3WavyProgress(value: 0.4, animate: animate);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('.*')), findsWidgets);
    set(() => animate = true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.hasScheduledFrame, isTrue);
    set(() => animate = false);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
