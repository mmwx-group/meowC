import 'package:bett_box/meowx/theme/meow_dialog.dart';
import 'package:bett_box/meowx/theme/morph_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 气泡 / 菜单开着时背后不挡手势（同 iOS 27，2026-11-18 用户：「气泡弹出后无法滑动屏幕，iOS 是可以的」）：
/// 在外面拖 = 关气泡并照常滚动；点外面 = 只关气泡，不落到下面的按钮上。
void main() {
  late BuildContext anchor;
  late ScrollController scroll;
  var taps = 0;

  Future<void> pumpPage(WidgetTester tester) async {
    taps = 0;
    scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: Builder(
                  builder: (context) {
                    anchor = context;
                    return const SizedBox(width: 48, height: 48);
                  },
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scroll,
                  children: [
                    for (var i = 0; i < 40; i++)
                      ListTile(key: ValueKey('row$i'), title: Text('行 $i'), onTap: () => taps++),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void openPopover() => showMeowPopover<void>(anchor, title: '气泡', width: 200, builder: (_) => const Text('里面'));

  testWidgets('popover：在外面拖，气泡关掉、列表照常滚动', (tester) async {
    await pumpPage(tester);
    openPopover();
    await tester.pumpAndSettle();
    expect(find.text('里面'), findsOneWidget);

    await tester.drag(find.byKey(const ValueKey('row6')), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('里面'), findsNothing);
    expect(scroll.offset, greaterThan(100));
  });

  testWidgets('popover：点外面只关气泡，不点到下面的行', (tester) async {
    await pumpPage(tester);
    openPopover();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('row4')));
    await tester.pumpAndSettle();
    expect(find.text('里面'), findsNothing);
    expect(taps, 0);
  });

  testWidgets('菜单：在外面拖同样关掉并滚动，点外面不点到下面', (tester) async {
    await pumpPage(tester);
    showMeowMenu<int>(anchor, entries: const [MeowMenuItem(1, '甲'), MeowMenuItem(2, '乙')]);
    await tester.pumpAndSettle();
    expect(find.text('乙'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('row4')));
    await tester.pumpAndSettle();
    expect(find.text('乙'), findsNothing);
    expect(taps, 0);

    showMeowMenu<int>(anchor, entries: const [MeowMenuItem(1, '甲'), MeowMenuItem(2, '乙')]);
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('row6')), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('乙'), findsNothing);
    expect(scroll.offset, greaterThan(100));
  });
}
