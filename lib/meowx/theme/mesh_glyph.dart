import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'svg_path.dart';

/// 喵窝图标：实心小猫头 + 一圈虚线私网边界 + 边界上三个设备节点（与 MeowX iOS / macOS 的 MeshGlyph 同一份几何，
/// MeowX 仓库 scripts/make-mesh-glyph.py）。实心图形，不走 [MeowIcon] 的描边画法，直接按 24 网格在画布上画。
class MeshGlyph extends StatelessWidget {
  const MeshGlyph({super.key, this.size = 22, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? Colors.black;
    return SizedBox.square(dimension: size, child: CustomPaint(painter: _MeshGlyphPainter(c)));
  }
}

class _MeshGlyphPainter extends CustomPainter {
  const _MeshGlyphPainter(this.color);

  final Color color;

  // 24 网格里的几何（同 make-mesh-glyph.py）：每 30° 一段虚线，节点所在的三段（-90° / 30° / 150°）整段不画，节点外留空隙
  static const _center = Offset(12, 12.5);
  static const _radius = 9.0;
  static const _ringWidth = 1.7;
  static const _dashArc = 2.25;
  static const _nodeRadius = 1.7;
  static const _nodes = [Offset(12, 3.5), Offset(4.2, 17), Offset(19.8, 17)];
  static const _head = 'M12 17.2c-2.6 0-4.4-1.8-4.4-4.3 0-.9.2-1.7.5-2.4l-.2-3.4 2.6 1.6c.5-.1 1-.2 1.5-.2c.5 0 1 .1 1.5 .2'
      'l2.6-1.6-.2 3.4c.3.7.5 1.5.5 2.4 0 2.5-1.8 4.3-4.4 4.3z';
  static final Path _headPath = parseSvgPath(_head);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _ringWidth
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final sweep = _dashArc / _radius;
    final rect = Rect.fromCircle(center: _center, radius: _radius);
    for (var k = 0; k < 12; k++) {
      if (k % 4 == 0) continue;
      final mid = (-90 + k * 30) * math.pi / 180;
      canvas.drawArc(rect, mid - sweep / 2, sweep, false, ring);
    }
    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    for (final n in _nodes) {
      canvas.drawCircle(n, _nodeRadius, fill);
    }
    canvas.drawPath(_headPath, fill);
  }

  @override
  bool shouldRepaint(_MeshGlyphPainter old) => old.color != color;
}
