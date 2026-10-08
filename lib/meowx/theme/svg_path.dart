import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// 把 SVG path 的 `d` 解析成 [Path]（坐标原样，不缩放）。
///
/// 只认线性图标用到的命令：M L H V C A Z 及小写的相对形式；省略命令字母的连写、
/// 负号 / 小数点紧挨着上一个数的写法（`l3-8 4 16`、`h.01`）都认。其它命令（S Q T）直接抛错，免得悄悄画歪。
/// 圆弧拆成三次贝塞尔（见 [_arcToCubics]），不用 [Path.arcToPoint]。
///
/// 图标原来是 flutter_svg 画的，这里要解析出同一条路径：同样的 `d` 画出来与它逐像素一致（test/meowx/theme/meow_icon_test.dart）。
Path parseSvgPath(String d) {
  final path = Path();
  final n = d.length;
  var i = 0;

  void skip() {
    while (i < n) {
      final c = d.codeUnitAt(i);
      if (c != 0x20 && c != 0x2C && c != 0x09 && c != 0x0A && c != 0x0D) break;
      i++;
    }
  }

  bool digit(int c) => c >= 0x30 && c <= 0x39;

  /// 后面还有没有数（= 同一个命令接着写下一组参数）
  bool more() {
    skip();
    if (i >= n) return false;
    final c = d.codeUnitAt(i);
    return digit(c) || c == 0x2D || c == 0x2B || c == 0x2E;
  }

  double number() {
    skip();
    final start = i;
    if (i < n && (d.codeUnitAt(i) == 0x2D || d.codeUnitAt(i) == 0x2B)) i++;
    var dot = false;
    while (i < n) {
      final c = d.codeUnitAt(i);
      if (c == 0x2E) {
        if (dot) break; // 第二个小数点是下一个数的开头（`1.5.5`）
        dot = true;
      } else if (!digit(c)) {
        break;
      }
      i++;
    }
    final v = double.tryParse(d.substring(start, i));
    if (v == null) throw FormatException('SVG path：这里应该是一个数', d, start);
    return v;
  }

  /// 圆弧的 large-arc / sweep 标志：只占一个字符，后面可以不留空格
  bool flag() {
    skip();
    final c = i < n ? d.codeUnitAt(i) : 0;
    if (c != 0x30 && c != 0x31) throw FormatException('SVG path：圆弧标志应该是 0 或 1', d, i);
    i++;
    return c == 0x31;
  }

  var x = 0.0, y = 0.0; // 当前点
  var startX = 0.0, startY = 0.0; // 当前子路径的起点（Z 之后回到这里）
  while (true) {
    skip();
    if (i >= n) break;
    final at = i;
    final code = d.codeUnitAt(i++);
    final rel = code >= 0x61; // 小写 = 相对坐标
    final cmd = String.fromCharCode(rel ? code - 0x20 : code);
    if (cmd == 'Z') {
      path.close();
      x = startX;
      y = startY;
      continue;
    }
    var first = true;
    do {
      final bx = rel ? x : 0.0, by = rel ? y : 0.0;
      switch (cmd) {
        case 'M':
          x = bx + number();
          y = by + number();
          // M 后面多出来的坐标对按 L 处理
          if (first) {
            path.moveTo(x, y);
            startX = x;
            startY = y;
          } else {
            path.lineTo(x, y);
          }
        case 'L':
          x = bx + number();
          y = by + number();
          path.lineTo(x, y);
        case 'H':
          x = bx + number();
          path.lineTo(x, y);
        case 'V':
          y = by + number();
          path.lineTo(x, y);
        case 'C':
          final x1 = bx + number(), y1 = by + number();
          final x2 = bx + number(), y2 = by + number();
          x = bx + number();
          y = by + number();
          path.cubicTo(x1, y1, x2, y2, x, y);
        case 'A':
          final rx = number(), ry = number(), rotation = number();
          final large = flag(), sweep = flag();
          final fromX = x, fromY = y;
          x = bx + number();
          y = by + number();
          _arcToCubics(path, fromX, fromY, rx, ry, rotation, large, sweep, x, y);
        default:
          throw FormatException('SVG path：不支持的命令', d, at);
      }
      first = false;
    } while (more());
  }
  return path;
}

/// SVG 圆弧（端点 + 半径 + 两个标志）→ 每段不超过 90° 的三次贝塞尔。
///
/// 做法与运算次序照 flutter_svg 用的 path_parsing（源自 Blink 的 SVG 路径归一化）：先把两个端点缩到单位圆的坐标系里
/// 求圆心和起止角，分段取贝塞尔控制点，再放大回去。它的变换矩阵是单精度的，这里的缩放 / 旋转系数也特意取单精度
/// （[_single]）——半径不是 2 的幂时圆心会因此偏 1e-7 量级，而 Skia 给曲线描边只精确到约 1/4 像素，这点偏差在小尺寸下
/// 足以让边缘像素差出一档。要和原来的图标逐像素一致，就得连这点误差一起对上；[Path.arcToPoint]（圆锥曲线）差得更多。
void _arcToCubics(
  Path path,
  double x0,
  double y0,
  double rx,
  double ry,
  double rotation,
  bool large,
  bool sweep,
  double x,
  double y,
) {
  rx = rx.abs();
  ry = ry.abs();
  // 半径为 0 或起止点重合：规范要求退化成直线
  if (rx == 0 || ry == 0 || (x0 == x && y0 == y)) {
    path.lineTo(x, y);
    return;
  }
  final angle = rotation * (math.pi / 180);
  final cos = math.cos(angle), sin = math.sin(angle);

  // 半径不够跨过这条弦时等比放大到刚好够（在转正了的坐标系里看弦的一半）
  final midX = (x0 - x) * 0.5, midY = (y0 - y) * 0.5;
  final tx = _single(cos) * midX + _single(sin) * midY, ty = _single(-sin) * midX + _single(cos) * midY;
  final radiiScale = tx * tx / (rx * rx) + ty * ty / (ry * ry);
  if (radiiScale > 1) {
    rx *= math.sqrt(radiiScale);
    ry *= math.sqrt(radiiScale);
  }

  // 画布 → 单位圆坐标系：先转正再按半径缩小
  final invRx = _single(1 / rx), invRy = _single(1 / ry);
  final a = _single(invRx * cos), b = _single(invRy * -sin), c = _single(invRx * sin), d = _single(invRy * cos);
  final p1x = a * x0 + c * y0, p1y = b * x0 + d * y0;
  final p2x = a * x + c * y, p2y = b * x + d * y;
  // 圆心在弦的中垂线上，离弦中点 sqrt(1 - 半弦长²)；两个标志决定取哪一侧
  var dx = p2x - p1x, dy = p2y - p1y;
  var k = math.sqrt(math.max(1 / (dx * dx + dy * dy) - 0.25, 0.0));
  if (!k.isFinite) k = 0;
  if (sweep == large) k = -k;
  dx *= k;
  dy *= k;
  final cx = (p1x + p2x) * 0.5 - dy, cy = (p1y + p2y) * 0.5 + dx;
  final theta1 = math.atan2(p1y - cy, p1x - cx);
  var arc = math.atan2(p2y - cy, p2x - cx) - theta1;
  if (arc < 0 && sweep) {
    arc += math.pi * 2;
  } else if (arc > 0 && !sweep) {
    arc -= math.pi * 2;
  }

  // 单位圆坐标系 → 画布：按半径放大再转回去
  final e = _single(_single(cos) * rx), f = _single(_single(sin) * rx);
  final g = _single(_single(-sin) * ry), h = _single(_single(cos) * ry);
  // 多出来的 0.001：正好 90° / 180° 的弧不因为浮点误差多拆出一段
  final segments = (arc / (math.pi / 2 + 0.001)).abs().ceil();
  for (var i = 0; i < segments; i++) {
    final start = theta1 + i * arc / segments, end = theta1 + (i + 1) * arc / segments;
    final t = (8 / 6) * math.tan(0.25 * (end - start));
    if (!t.isFinite) {
      path.lineTo(x, y);
      return;
    }
    final sinStart = math.sin(start), cosStart = math.cos(start);
    final sinEnd = math.sin(end), cosEnd = math.cos(end);
    final c1x = cosStart - t * sinStart + cx, c1y = sinStart + t * cosStart + cy;
    final endX = cosEnd + cx, endY = sinEnd + cy;
    final c2x = endX + t * sinEnd, c2y = endY - t * cosEnd;
    path.cubicTo(
      e * c1x + g * c1y,
      f * c1x + h * c1y,
      e * c2x + g * c2y,
      f * c2x + h * c2y,
      e * endX + g * endY,
      f * endX + h * endY,
    );
  }
}

final _singleCell = Float32List(1);

/// 舍入到单精度再读回来
double _single(double value) {
  _singleCell[0] = value;
  return _singleCell[0];
}
