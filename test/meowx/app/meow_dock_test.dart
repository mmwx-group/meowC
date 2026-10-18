import 'package:bett_box/meowx/app/meow_dock.dart';
import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/glass/liquid_glass.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<int>> _pumpDock(WidgetTester tester, {int selected = 0}) async {
  final picked = <int>[];
  tester.view.physicalSize = const Size(412 * 3, 892 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: meowThemeData(brightness: Brightness.light),
    home: LiquidGlassScope(
      enabled: true,
      child: LiquidGlassHost(
        enabled: true,
        child: Scaffold(
          extendBody: true,
          body: const SizedBox.expand(),
          bottomNavigationBar: NavigationDock(
            destinations: [for (final t in MeowTab.values) NavigationDockDestination(glyph: t.glyph, label: t.label)],
            selectedIndex: selected,
            onSelected: picked.add,
          ),
        ),
      ),
    ),
  ));
  return picked;
}

void main() {
  testWidgets('底栏：点哪项选哪项，点当前项不重复选', (tester) async {
    final picked = await _pumpDock(tester);
    for (final t in MeowTab.values) {
      expect(find.text(t.label), findsOneWidget);
    }
    await tester.tap(find.text(MeowTab.values[2].label));
    await tester.pumpAndSettle();
    expect(picked, [2]);
    await tester.tap(find.text(MeowTab.values[0].label));
    await tester.pumpAndSettle();
    expect(picked, [2], reason: '点的是已选中的那项');
  });

  testWidgets('底栏：按住拖到别的项上松手，选中松手处', (tester) async {
    final picked = await _pumpDock(tester);
    final from = tester.getCenter(find.text(MeowTab.values[0].label));
    final to = tester.getCenter(find.text(MeowTab.values[3].label));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(picked, [3]);
  });
}
