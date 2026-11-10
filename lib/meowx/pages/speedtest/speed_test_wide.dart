import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 测速页、测速记录、记录详情的宽版（两栏）判定：按页面自己的可用尺寸，不看平台——Windows / Linux 的窗口可以拉窄，
/// 安卓平板与手机横屏也该用宽版。
///
/// 条件：宽 ≥ 高（横着放），且宽 ≥ [speedTestWideMinWidth]。
/// 680 的来历：两栏各要至少约 316 宽才放得下（680 − 左右边距 16×2 − 栏间距 16 = 632，一栏 316），
/// 这是手机竖屏单列卡片宽度（360 宽的手机去掉两边 16 = 328）的量级：右栏延迟 / 下载 / 上传三格各约 89 宽，
/// 与手机竖屏上（约 92）相当，「486.4 Mbps」这样的读数不会挤；再窄的横窗口两栏都会挤，宁可用原来的单列。
/// 竖着的窗口（宽 < 高，如平板竖屏、拉高的桌面窗口）单列本来就放得下，仍用原来的版式。
const speedTestWideMinWidth = 680.0;

/// 宽版的页面最宽多少（单列二级页是 720）：再宽两栏之间、卡片里只是空白
const speedTestWideMaxWidth = 1080.0;

bool speedTestWide(Size size) => size.width >= speedTestWideMinWidth && size.width >= size.height;

/// 宽版的两栏：左右等宽、顶对齐，整体放在可滚动区里——一屏放得下时可滚动距离是 0；窗口实在矮才滚。
/// 每栏是一个 [FillColumn]：可伸缩的卡片（码表卡、读数 / 曲线卡、详情曲线卡）把剩下的高度吃满，两栏底边对齐。
class SpeedTestTwoColumns extends StatelessWidget {
  const SpeedTestTwoColumns({super.key, required this.left, required this.right, this.controller});

  final List<Widget> left, right;

  /// 测试里看滚动距离
  final ScrollController? controller;

  static const gap = 16.0, spacing = 12.0;

  @override
  Widget build(BuildContext context) {
    final bottom = 16 + MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, c) {
        final height = math.max(0.0, c.maxHeight - bottom);
        return SingleChildScrollView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: FillColumn(height: height, spacing: spacing, children: left)),
              const SizedBox(width: gap),
              Expanded(child: FillColumn(height: height, spacing: spacing, children: right)),
            ],
          ),
        );
      },
    );
  }
}

/// 一列：子项横向撑满、按顺序竖排，间距 [spacing]；用 [FillColumn.flex] 包住的子项分掉剩下的高度（按 flex 比例），
/// 但不小于各自的 min。
///
/// - 上面给了有界高度（例如它本身是外层 [FillColumn] 里可伸缩的那一项）：按这个高度分，剩得不够就把可伸缩的压到 0（不守 min）；
/// - 上面高度无界（放在滚动区里）：按 [height]（视口高度）分，剩得不够时可伸缩的取 min，整列比视口高、外面滚动。
///
/// 为什么不用 Column + Expanded：Expanded 放进滚动区要有界高度，而「放得下就撑满、放不下就按最小高度滚」要先知道
/// 其余子项的实际高度（字号缩放、测速榜那一条有没有都会变），这里就地量，不估算。
class FillColumn extends MultiChildRenderObjectWidget {
  const FillColumn({super.key, this.height, this.spacing = 12, required super.children});

  /// 高度无界时按它分剩下的空间（视口高度）；null = 可伸缩的子项一律取 min
  final double? height;
  final double spacing;

  /// 可伸缩的子项：分剩下的高度，至少 [min]
  static Widget flex({Key? key, double min = 0, int flex = 1, required Widget child}) =>
      _FillSlot(key: key, min: min, flex: flex, child: child);

  @override
  RenderFillColumn createRenderObject(BuildContext context) => RenderFillColumn(height: height, spacing: spacing);

  @override
  void updateRenderObject(BuildContext context, RenderFillColumn renderObject) {
    renderObject
      ..height = height
      ..spacing = spacing;
  }
}

class _FillSlot extends ParentDataWidget<FillColumnParentData> {
  const _FillSlot({super.key, required this.min, required this.flex, required super.child});
  final double min;
  final int flex;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as FillColumnParentData;
    if (data.min != min || data.flex != flex) {
      data
        ..min = min
        ..flex = flex;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => FillColumn;
}

class FillColumnParentData extends ContainerBoxParentData<RenderBox> {
  /// 非 null = 可伸缩
  double? min;
  int flex = 1;
}

class RenderFillColumn extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, FillColumnParentData>, RenderBoxContainerDefaultsMixin<RenderBox, FillColumnParentData> {
  RenderFillColumn({double? height, double spacing = 12}) : _height = height, _spacing = spacing;

  double? _height;
  double? get height => _height;
  set height(double? value) {
    if (value == _height) return;
    _height = value;
    markNeedsLayout();
  }

  double _spacing;
  double get spacing => _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! FillColumnParentData) child.parentData = FillColumnParentData();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final loose = BoxConstraints.tightFor(width: width);
    var fixed = 0.0, mins = 0.0, flexes = 0, count = 0;
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as FillColumnParentData;
      count++;
      if (data.min == null) {
        child.layout(loose, parentUsesSize: true);
        fixed += child.size.height;
      } else {
        mins += data.min!;
        flexes += data.flex;
      }
      child = data.nextSibling;
    }
    final gaps = count > 1 ? spacing * (count - 1) : 0.0;
    final bounded = constraints.hasBoundedHeight;
    final target = bounded ? constraints.maxHeight : (height ?? 0);
    final slack = target - fixed - gaps;
    // 有界：按给的高度分，不够就压缩（不守 min，免得画出界）；无界：不够时取 min，整列比视口高
    final flexTotal = bounded ? math.max(0.0, slack) : math.max(slack, mins);
    final extra = bounded ? flexTotal : flexTotal - mins;
    var y = 0.0;
    child = firstChild;
    while (child != null) {
      final data = child.parentData! as FillColumnParentData;
      if (data.min != null) {
        final share = flexes == 0 ? 0.0 : extra * data.flex / flexes;
        final h = bounded ? share : data.min! + share;
        child.layout(BoxConstraints.tightFor(width: width, height: math.max(0.0, h)), parentUsesSize: true);
      }
      data.offset = Offset(0, y);
      y += child.size.height + spacing;
      child = data.nextSibling;
    }
    size = constraints.constrain(Size(width, count == 0 ? 0 : y - spacing));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
