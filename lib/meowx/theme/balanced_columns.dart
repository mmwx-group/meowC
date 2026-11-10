import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 宽屏三列：第 1 列固定宽、顶上放 [lead]（账户 + 订阅），[sections] 按原顺序**连续**切成三段，
/// 依次接在 lead 下面、第 2 列、第 3 列（读起来仍是一列一列往下），切点按实际排出来的高度选，让最高的一列尽量矮。
///
/// 以前是固定分配（Windows：第 2 列只放平台专属分组、通用分组全在第 3 列），第 3 列比另外两列高出一千多像素，
/// 三列又在同一个滚动区里，往下滚时左边两列整个滚没、只剩一大片空白（#1772）。
///
/// 卡片里拨开关会让卡片变高、触发重新切分：新切法比现在的切法矮不到 [_stickiness] 就不换，免得点一下开关整张卡片跳到别的列。
class BalancedColumns extends MultiChildRenderObjectWidget {
  BalancedColumns({
    super.key,
    required Widget lead,
    required List<Widget> sections,
    this.leadWidth = 292,
    this.columnGap = 12,
    this.sectionGap = 10,
    this.leadGap = 12,
  }) : super(children: [lead, ...sections]);

  final double leadWidth;
  final double columnGap;
  final double sectionGap;

  /// lead 与接在它下面的第一个分组之间的间距。
  final double leadGap;

  @override
  RenderBalancedColumns createRenderObject(BuildContext context) => RenderBalancedColumns(
    leadWidth: leadWidth,
    columnGap: columnGap,
    sectionGap: sectionGap,
    leadGap: leadGap,
  );

  @override
  void updateRenderObject(BuildContext context, RenderBalancedColumns renderObject) {
    renderObject
      ..leadWidth = leadWidth
      ..columnGap = columnGap
      ..sectionGap = sectionGap
      ..leadGap = leadGap;
  }
}

/// 切点：分组 `[0, first)` 接在 lead 下面，`[first, second)` 在第 2 列，`[second, n)` 在第 3 列。
typedef ColumnSplit = ({int first, int second});

/// 三列各自的高度（不含切点之外的东西）。[inLead] 是各分组排在第 1 列宽度下的高度，[inColumn] 是排在第 2 / 3 列宽度下的高度。
List<double> columnHeights(
  ColumnSplit split, {
  required double lead,
  required List<double> inLead,
  required List<double> inColumn,
  required double sectionGap,
  required double leadGap,
}) {
  double stack(List<double> hs, int from, int to) {
    var h = 0.0;
    for (var k = from; k < to; k++) {
      h += hs[k] + (k > from ? sectionGap : 0);
    }
    return h;
  }

  final under = stack(inLead, 0, split.first);
  return [
    lead + (split.first > 0 ? leadGap + under : 0),
    stack(inColumn, split.first, split.second),
    stack(inColumn, split.second, inColumn.length),
  ];
}

/// 选让最高一列最矮的连续切法；一样高时选三列高低差最小的，再一样时 lead 下面少放（第 1 列以账户、订阅为主）。
ColumnSplit balancedSplit({
  required double lead,
  required List<double> inLead,
  required List<double> inColumn,
  required double sectionGap,
  required double leadGap,
}) {
  assert(inLead.length == inColumn.length);
  final n = inColumn.length;
  ColumnSplit best = (first: 0, second: 0);
  var bestMax = double.infinity;
  var bestSpread = double.infinity;
  for (var i = 0; i <= n; i++) {
    for (var j = i; j <= n; j++) {
      final hs = columnHeights((first: i, second: j), lead: lead, inLead: inLead, inColumn: inColumn, sectionGap: sectionGap, leadGap: leadGap);
      final top = hs.reduce(math.max);
      final spread = top - hs.reduce(math.min);
      // 浮点误差内算一样高
      if (top < bestMax - 0.5 || (top <= bestMax + 0.5 && spread < bestSpread - 0.5)) {
        best = (first: i, second: j);
        bestMax = top;
        bestSpread = spread;
      }
    }
  }
  return best;
}

class _ColumnsParentData extends ContainerBoxParentData<RenderBox> {}

class RenderBalancedColumns extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ColumnsParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _ColumnsParentData> {
  RenderBalancedColumns({required double leadWidth, required double columnGap, required double sectionGap, required double leadGap})
    : _leadWidth = leadWidth,
      _columnGap = columnGap,
      _sectionGap = sectionGap,
      _leadGap = leadGap;

  /// 新切法要比沿用上一次的切法矮这么多才换（大约一行设置的高度）。
  static const _stickiness = 48.0;

  double _leadWidth;
  double get leadWidth => _leadWidth;
  set leadWidth(double v) {
    if (v == _leadWidth) return;
    _leadWidth = v;
    markNeedsLayout();
  }

  double _columnGap;
  double get columnGap => _columnGap;
  set columnGap(double v) {
    if (v == _columnGap) return;
    _columnGap = v;
    markNeedsLayout();
  }

  double _sectionGap;
  double get sectionGap => _sectionGap;
  set sectionGap(double v) {
    if (v == _sectionGap) return;
    _sectionGap = v;
    markNeedsLayout();
  }

  double _leadGap;
  double get leadGap => _leadGap;
  set leadGap(double v) {
    if (v == _leadGap) return;
    _leadGap = v;
    markNeedsLayout();
  }

  /// 上一次用的切法与当时的分组个数（个数变了就不沿用）。
  ColumnSplit? _lastSplit;
  int _lastCount = -1;

  /// 测试用：当前切法。
  @visibleForTesting
  ColumnSplit? get split => _lastSplit;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ColumnsParentData) child.parentData = _ColumnsParentData();
  }

  double _layoutAt(RenderBox child, double width) {
    child.layout(BoxConstraints.tightFor(width: math.max(0, width)), parentUsesSize: true);
    return child.size.height;
  }

  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth, 'BalancedColumns 需要有限的宽度');
    final width = constraints.maxWidth;
    final lead = firstChild;
    if (lead == null) {
      size = constraints.constrain(Size(width, 0));
      return;
    }
    final leadW = math.min(_leadWidth, width);
    final colW = math.max(0.0, (width - leadW - 2 * _columnGap) / 2);
    final leadH = _layoutAt(lead, leadW);

    final sections = <RenderBox>[];
    for (var c = childAfter(lead); c != null; c = childAfter(c)) {
      sections.add(c);
    }
    final inLead = [for (final s in sections) _layoutAt(s, leadW)];
    final inColumn = [for (final s in sections) _layoutAt(s, colW)];

    var split = balancedSplit(lead: leadH, inLead: inLead, inColumn: inColumn, sectionGap: _sectionGap, leadGap: _leadGap);
    final last = _lastSplit;
    if (last != null && _lastCount == sections.length && last != split) {
      double tallest(ColumnSplit s) => columnHeights(s, lead: leadH, inLead: inLead, inColumn: inColumn, sectionGap: _sectionGap, leadGap: _leadGap).reduce(math.max);
      if (tallest(last) - tallest(split) < _stickiness) split = last;
    }
    _lastSplit = split;
    _lastCount = sections.length;

    (lead.parentData! as _ColumnsParentData).offset = Offset.zero;
    final xs = [0.0, leadW + _columnGap, leadW + _columnGap + colW + _columnGap];
    final ys = [leadH, 0.0, 0.0];
    final placed = [true, false, false];
    for (final (k, s) in sections.indexed) {
      final col = k < split.first ? 0 : (k < split.second ? 1 : 2);
      // 最后量的是第 2 / 3 列的宽度，放进第 1 列的要按第 1 列重排一次
      final h = col == 0 ? _layoutAt(s, leadW) : inColumn[k];
      if (placed[col]) ys[col] += k == 0 ? _leadGap : _sectionGap;
      (s.parentData! as _ColumnsParentData).offset = Offset(xs[col], ys[col]);
      ys[col] += h;
      placed[col] = true;
    }
    size = constraints.constrain(Size(width, ys.reduce(math.max)));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
}
