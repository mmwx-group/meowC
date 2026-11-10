import 'package:bett_box/meowx/theme/balanced_columns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ColumnSplit _split(double lead, List<double> hs) =>
    balancedSplit(lead: lead, inLead: hs, inColumn: hs, sectionGap: 10, leadGap: 12);

List<double> _heights(ColumnSplit s, double lead, List<double> hs) =>
    columnHeights(s, lead: lead, inLead: hs, inColumn: hs, sectionGap: 10, leadGap: 12);

/// 一组宽 100%、高度可改的色块。
class _Blocks extends StatefulWidget {
  const _Blocks({super.key, required this.lead, required this.heights});

  final double lead;
  final List<double> heights;

  @override
  State<_Blocks> createState() => _BlocksState();
}

class _BlocksState extends State<_Blocks> {
  late List<double> heights = [...widget.heights];

  void setHeight(int i, double h) => setState(() => heights[i] = h);

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: BalancedColumns(
      lead: SizedBox(key: const ValueKey('lead'), height: widget.lead),
      sections: [for (final (i, h) in heights.indexed) SizedBox(key: ValueKey(i), height: h)],
    ),
  );
}

void main() {
  test('连续切三段：最高一列尽量矮，顺序不变', () {
    // 以前的 Windows 分法：lead 560 | 平台三组 | 其余五组（外观最高）
    const hs = [170.0, 140.0, 210.0, 180.0, 220.0, 260.0, 240.0, 680.0];
    const lead = 560.0;
    final s = _split(lead, hs);
    final h = _heights(s, lead, hs);
    final old = _heights((first: 0, second: 3), lead, hs);
    expect(h.reduce((a, b) => a > b ? a : b), lessThan(old.reduce((a, b) => a > b ? a : b) - 500));
    // 三段都满足 0 ≤ first ≤ second ≤ n
    expect(s.first, inInclusiveRange(0, s.second));
    expect(s.second, inInclusiveRange(s.first, hs.length));
  });

  test('lead 本身就最高：分组都不接在它下面，两列对半', () {
    final s = _split(2000, const [100, 100, 100, 100]);
    expect(s, (first: 0, second: 2));
  });

  test('没有分组 / 只有一个分组', () {
    expect(_split(300, const []), (first: 0, second: 0));
    final one = _split(300, const [500]);
    expect(_heights(one, 300, const [500]).reduce((a, b) => a > b ? a : b), 500);
  });

  test('最高一列一样高时选三列高低差小的', () {
    // lead 最高（500）：两个分组一列一个（100 / 100），不挤在同一列（210 / 0）
    expect(_split(500, const [100, 100]), (first: 0, second: 1));
  });

  testWidgets('排版：分组按切法摆进三列；第 1 列宽度固定，第 2 / 3 列平分余下宽度', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: _Blocks(lead: 300, heights: [200, 200, 200, 200, 200]),
    ));
    expect(tester.getSize(find.byKey(const ValueKey('lead'))).width, 292);
    final colW = (1000 - 292 - 24) / 2;
    final lefts = <double>{};
    for (var i = 0; i < 5; i++) {
      final r = tester.getRect(find.byKey(ValueKey(i)));
      lefts.add(r.left);
      expect(r.width, r.left == 0 ? 292 : colW);
    }
    expect(lefts, {0.0, 304.0, 304.0 + colW + 12});
    // 总高 = 最高一列
    final render = tester.renderObject<RenderBalancedColumns>(find.byType(BalancedColumns));
    final hs = [300 + 12 + 200.0, 410.0, 410.0];
    expect(render.size.height, hs.reduce((a, b) => a > b ? a : b));
    expect(render.split, (first: 1, second: 3));
  });

  testWidgets('分组变高一点（拨开关多出一行）不换列；变高很多才重新切', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<_BlocksState>();
    const lead = 300.0;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: _Blocks(key: key, lead: lead, heights: const [300, 150, 100, 150, 300]),
    ));
    final render = tester.renderObject<RenderBalancedColumns>(find.byType(BalancedColumns));
    final before = render.split!;

    // 第 3 列最后一组长高 40：重新算的话最优切法变了，但只矮 40，不值得让卡片跳列
    key.currentState!.setHeight(4, 340);
    await tester.pump();
    const grown = <double>[300, 150, 100, 150, 340];
    expect(_split(lead, grown), isNot(before));
    expect(render.split, before);
    expect(render.size.height, _heights(before, lead, grown).reduce((a, b) => a > b ? a : b));

    // 长高 600：原切法比最优高出一大截，换
    key.currentState!.setHeight(4, 900);
    await tester.pump();
    expect(render.split, _split(lead, const [300, 150, 100, 150, 900]));
    expect(render.split, isNot(before));
  });
}
