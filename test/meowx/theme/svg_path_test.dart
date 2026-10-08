import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:bett_box/meowx/theme/svg_path.dart';
import 'package:flutter_test/flutter_test.dart';

/// 量长度 / 取点之前先放大：引擎量曲线时按约半个单位的精度把它拆成折线，24 网格里的小圆弧原样量会糙到没法比。
const _zoom = 256.0;

PathMetric _metric(Path path) {
  final zoomed = path.transform(Float64List.fromList([_zoom, 0, 0, 0, 0, _zoom, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]));
  return zoomed.computeMetrics().single;
}

/// 路径长度。只有一条子路径的路径用。
double _length(Path path) => _metric(path).length / _zoom;

/// 路径上走到 [fraction]（0–1）处的点。只有一条子路径的路径用。
Offset _pointAt(Path path, double fraction) {
  final metric = _metric(path);
  return metric.getTangentForOffset(metric.length * fraction)!.position / _zoom;
}

void main() {
  test('直线：绝对 / 相对、H V、省略命令字母的连写、紧挨着的负号和小数点', () {
    expect(parseSvgPath('M4 5h16v14H4z').getBounds(), const Rect.fromLTRB(4, 5, 20, 19));
    // l 后面连写三组；-8 紧挨着上一个数
    expect(parseSvgPath('M3 12h4l3-8 4 16 3-8h4').getBounds(), const Rect.fromLTRB(3, 4, 21, 20));
    // L / V 的绝对形式；逗号分隔
    expect(parseSvgPath('M6,6 L18,18 M12 19V5').getBounds(), const Rect.fromLTRB(6, 5, 18, 19));
    // h.01：小数点开头的数；M 后面多出来的坐标对按直线
    expect(_length(parseSvgPath('M7 11h.01')), closeTo(0.01, 1e-6));
    expect(_length(parseSvgPath('M1 1 5 1 5 4')), closeTo(7, 1e-6));
    // m 的相对形式：第二条子路径从上一条的终点算起
    expect(parseSvgPath('M2 2h2m1 1h2').getBounds(), const Rect.fromLTRB(2, 2, 7, 3));
  });

  test('Z 之后当前点回到子路径起点', () {
    // 闭合后的相对命令从 (4,4) 算起（到 (2,3)），不是从最后一个顶点 (4,8)
    final path = parseSvgPath('M4 4h4v4h-4zl-2-1');
    expect(path.getBounds(), const Rect.fromLTRB(2, 3, 8, 8));
  });

  test('三次贝塞尔：绝对 / 相对、连写', () {
    final abs = parseSvgPath('M12 3C15 6 15 18 12 21');
    final rel = parseSvgPath('M12 3c3 3 3 15 0 18');
    expect(rel.getBounds(), abs.getBounds());
    expect(_pointAt(rel, 0.5).dx, closeTo(14.25, 1e-3));
    // 盾牌：c 后面连写四段，V + z 收口
    final shield = parseSvgPath('M12 3l7 3v5c0 5-3 8-7 10-4-2-7-5-7-10V6z');
    expect(shield.getBounds(), const Rect.fromLTRB(5, 3, 19, 21));
  });

  test('圆弧：两段半圆拼成整圆，长度、走向、半径都对', () {
    // 圆心 (12,12)、半径 9；第一段 sweep=0：从顶点出发往左（逆时针）绕到底
    final circle = parseSvgPath('M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18');
    expect(_length(circle), closeTo(2 * math.pi * 9, 0.02));
    final quarter = _pointAt(circle, 0.25);
    expect(quarter.dx, closeTo(3, 0.01));
    expect(quarter.dy, closeTo(12, 0.01));
    final threeQuarters = _pointAt(circle, 0.75);
    expect(threeQuarters.dx, closeTo(21, 0.01));
    // 整条路径上每一点到圆心都是 9（贝塞尔近似的误差远小于 0.01）
    for (var i = 0; i <= 40; i++) {
      expect((_pointAt(circle, i / 40) - const Offset(12, 12)).distance, closeTo(9, 0.01));
    }
  });

  test('圆弧：sweep=1 顺时针；large-arc 选大的那一段；标志后面不留空格也认', () {
    // 首页图标右下角的小圆角
    final corner = parseSvgPath('M20 19a1 1 0 0 1-1 1');
    expect(_length(corner), closeTo(math.pi / 2, 1e-3));
    final mid = _pointAt(corner, 0.5);
    // 圆心 (19,19)，顺时针走过右下 45° 的点
    expect(mid.dx, closeTo(19 + math.sqrt1_2, 1e-3));
    expect(mid.dy, closeTo(19 + math.sqrt1_2, 1e-3));

    // 「刷新」的大弧：起止点很近，large-arc=1 要绕远的那一圈
    final refresh = parseSvgPath('M20 12a8 8 0 1 1-2.3-5.7');
    expect(_length(refresh), greaterThan(2 * math.pi * 8 * 0.8));
    // 两个标志和后面的数粘在一起写
    final packed = parseSvgPath('M20 12a8 8 0 11-2.3-5.7');
    expect(_length(packed), closeTo(_length(refresh), 1e-9));
  });

  test('圆弧：半径不够跨过弦时放大到刚好够；半径为 0 退化成直线', () {
    // 弦长 10、半径只给 1：按规范放大成直径 10 的半圆
    final scaled = parseSvgPath('M0 0a1 1 0 0 1 10 0');
    expect(_length(scaled), closeTo(math.pi * 5, 0.01));
    final line = parseSvgPath('M0 0a0 5 0 0 1 10 0');
    expect(_length(line), closeTo(10, 1e-6));
  });

  test('不认识的命令 / 写坏的数直接抛错，不悄悄画歪', () {
    expect(() => parseSvgPath('M0 0q5 5 10 0'), throwsFormatException);
    expect(() => parseSvgPath('M0 0s5 5 10 0'), throwsFormatException);
    expect(() => parseSvgPath('M0 0l5'), throwsFormatException);
    expect(() => parseSvgPath('M0 0a5 5 0 2 1 10 0'), throwsFormatException);
    expect(parseSvgPath('').computeMetrics(), isEmpty);
  });
}
