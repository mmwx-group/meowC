import 'dart:ui';

import 'package:bett_box/meowx/state/window_placement.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按物理像素描述一块屏（任务栏 48 物理像素在底部），换成 screen_retriever 口径。
DisplayArea screen(double left, double top, double width, double height, double scale) =>
    DisplayArea(
      Rect.fromLTWH(left / scale, top / scale, width / scale, (height - 48) / scale),
      scale,
    );

const size = Size(910, 620);

void main() {
  // 主屏 2560×1600 @150%，副屏 1920×1080 @100% 接在右边
  final laptop = screen(0, 0, 2560, 1600, 1.5);
  final external = screen(2560, 0, 1920, 1080, 1);

  test('单屏：原样还原', () {
    final p = restoreWindowPosition(
      saved: const Offset(200, 100),
      size: size,
      displays: [laptop],
      currentScale: 1.5,
    );
    expect(p, const Offset(200, 100));
  });

  test('窗口存在 100% 副屏、启动时在 150% 主屏：换算后落回副屏同一物理位置', () {
    // 副屏物理 (2800, 200) → getBounds 按 100% 存成 (2800, 200)
    final p = restoreWindowPosition(
      saved: const Offset(2800, 200),
      size: size,
      displays: [laptop, external],
      currentScale: 1.5,
    )!;
    // setPosition 会 ×1.5，所以要传物理 ÷ 1.5
    expect(p.dx * 1.5, closeTo(2800, 0.01));
    expect(p.dy * 1.5, closeTo(200, 0.01));
  });

  test('窗口存在 150% 主屏、启动时在 100% 副屏：同样按物理坐标还原', () {
    final p = restoreWindowPosition(
      saved: const Offset(300, 200), // 主屏物理 (450, 300)
      size: size,
      displays: [laptop, external],
      currentScale: 1,
    )!;
    expect(p, const Offset(450, 300));
  });

  test('副屏接在主屏左边（负坐标）', () {
    final left = screen(-1920, 0, 1920, 1080, 1);
    final p = restoreWindowPosition(
      saved: const Offset(-1500, 100),
      size: size,
      displays: [laptop, left],
      currentScale: 1.5,
    )!;
    expect(p.dx * 1.5, closeTo(-1500, 0.01));
  });

  test('副屏已拔掉：返回 null（调用方居中）', () {
    final p = restoreWindowPosition(
      saved: const Offset(2800, 200),
      size: size,
      displays: [screen(0, 0, 1920, 1080, 1)],
      currentScale: 1,
    );
    expect(p, isNull);
  });

  test('标题栏只露出一角：不算可见', () {
    final p = restoreWindowPosition(
      saved: const Offset(1900, 100), // 单屏 1920 宽，只剩 20 像素
      size: size,
      displays: [screen(0, 0, 1920, 1080, 1)],
      currentScale: 1,
    );
    expect(p, isNull);
  });

  test('右 / 下超出屏幕但标题栏可见：收回屏内', () {
    final p = restoreWindowPosition(
      saved: const Offset(1500, 800),
      size: size,
      displays: [screen(0, 0, 1920, 1080, 1)],
      currentScale: 1,
    );
    expect(p, const Offset(1920 - 910, 1080 - 48 - 620));
  });

  test('窗口比屏幕还大：贴左上角', () {
    final p = restoreWindowPosition(
      saved: const Offset(100, 100),
      size: const Size(3000, 2000),
      displays: [screen(0, 0, 1920, 1080, 1)],
      currentScale: 1,
    );
    expect(p, Offset.zero);
  });

  test('坐标非有限值：返回 null', () {
    expect(
      restoreWindowPosition(
        saved: const Offset(double.nan, 0),
        size: size,
        displays: [laptop],
        currentScale: 1.5,
      ),
      isNull,
    );
  });
}
