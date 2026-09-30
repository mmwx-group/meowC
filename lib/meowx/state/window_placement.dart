import 'dart:math' as math;
import 'dart:ui';

/// 一块显示器的工作区。Windows 上三方插件的坐标口径各不相同，多屏且缩放不一致时混用就会把窗口放到屏幕外：
/// - screen_retriever：工作区 = 物理像素 ÷ 该屏自己的缩放（[visible]、[scale]）
/// - window_manager.getBounds：物理像素 ÷ 窗口当时所在屏的缩放（存盘的 left / top 就是这个）
/// - window_manager.setPosition：传入值 × 窗口当前所在屏的缩放（启动时通常是主屏）
class DisplayArea {
  final Rect visible;
  final double scale;

  const DisplayArea(this.visible, this.scale);

  Rect get physical => Rect.fromLTRB(
        visible.left * scale,
        visible.top * scale,
        visible.right * scale,
        visible.bottom * scale,
      );
}

/// 标题栏里至少要露出这么大一块（逻辑像素）才算「能拖回来」。
const _grabWidth = 160.0;
const _grabHeight = 32.0;

/// screen_retriever 对工作区做了 round，换算回物理像素会有几个像素的误差。
const _tolerance = 4.0;

/// 把存盘的窗口位置换算成这次该传给 `setPosition` 的坐标。
///
/// [saved] 是 getBounds 口径的左上角，[size] 是窗口逻辑尺寸，[currentScale] 是窗口此刻所在屏的缩放
/// （`windowManager.getDevicePixelRatio()`）。逐屏假设「当时就在这块屏上」换算成物理坐标，标题栏能完整落进
/// 该屏工作区的就用它，并把超出右 / 下边的部分收回屏内；没有任何一块屏放得下（拔了显示器、分辨率变了）返回 null，
/// 由调用方居中。
Offset? restoreWindowPosition({
  required Offset saved,
  required Size size,
  required List<DisplayArea> displays,
  required double currentScale,
}) {
  if (!saved.dx.isFinite || !saved.dy.isFinite || currentScale <= 0) return null;
  for (final d in displays) {
    if (d.scale <= 0) continue;
    final area = d.physical;
    final p = saved * d.scale;
    final grab = Rect.fromLTWH(
      p.dx,
      p.dy,
      math.min(size.width, _grabWidth) * d.scale,
      _grabHeight * d.scale,
    );
    if (!area.inflate(_tolerance).contains(grab.topLeft) ||
        !area.inflate(_tolerance).contains(grab.bottomRight)) {
      continue;
    }
    final width = size.width * d.scale;
    final height = size.height * d.scale;
    final x = p.dx.clamp(area.left, math.max(area.left, area.right - width));
    final y = p.dy.clamp(area.top, math.max(area.top, area.bottom - height));
    return Offset(x / currentScale, y / currentScale);
  }
  return null;
}
