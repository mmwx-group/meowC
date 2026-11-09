import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/meowx/theme/mesh_glyph.dart';

void main() {
  testWidgets('喵窝图标按给定尺寸画、颜色传给画笔', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: MeshGlyph(size: 40, color: Colors.pink)),
    ));
    final box = tester.getSize(find.byType(MeshGlyph));
    expect(box, const Size(40, 40));
    expect(find.descendant(of: find.byType(MeshGlyph), matching: find.byType(CustomPaint)), findsOneWidget);
  });
}
