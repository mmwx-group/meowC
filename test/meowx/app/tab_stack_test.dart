import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/app/tab_stack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 撑满的探针页：每次拿到新约束（= 被重排）回调一次。
class _Probe extends StatelessWidget {
  const _Probe(this.onLayout);
  final void Function(BuildContext context, BoxConstraints constraints) onLayout;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        onLayout(context, c);
        return const SizedBox.expand();
      },
    );
  }
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => TextButton(onPressed: () => setState(() => taps++), child: Text('点了 $taps 次'));
}

void main() {
  group('MeowTabStack', () {
    Widget stack(MeowTab current, Widget Function(MeowTab) pageBuilder) => MaterialApp(
      home: Scaffold(body: MeowTabStack(current: current, pageBuilder: pageBuilder)),
    );

    // 「动态」页一直挂着一个转圈（核心在跑、页面没加载完时就是这样）
    Widget pages(MeowTab t) => switch (t) {
      MeowTab.connections => const Center(child: CircularProgressIndicator()),
      MeowTab.proxies => const _Counter(),
      _ => Text(t.label),
    };

    testWidgets('隐藏页里的转圈不出帧：停在别的页时整个 App 是闲的', (tester) async {
      await tester.pumpWidget(stack(MeowTab.home, pages));
      await tester.pump();
      // 对照：不静音的话（裸 IndexedStack 就是这样）隐藏的转圈每一帧都在要下一帧
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.byType(CircularProgressIndicator, skipOffstage: false), findsOneWidget);

      // 切到它所在的页：开始转
      await tester.pumpWidget(stack(MeowTab.connections, pages));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);

      // 切走：又停了
      await tester.pumpWidget(stack(MeowTab.me, pages));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('对照：裸 IndexedStack 里隐藏的转圈一直在要帧', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IndexedStack(index: MeowTab.home.index, children: [for (final t in MeowTab.values) pages(t)]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('只有当前页的 Ticker 开着；四页都留在树上，切走再回来状态还在', (tester) async {
      final enabled = <MeowTab, bool>{};
      Widget probes(MeowTab t) => t == MeowTab.proxies
          ? const _Counter()
          : Builder(
              builder: (context) {
                enabled[t] = TickerMode.valuesOf(context).enabled;
                return Text(t.label);
              },
            );

      await tester.pumpWidget(stack(MeowTab.proxies, probes));
      expect(enabled, {MeowTab.home: false, MeowTab.connections: false, MeowTab.me: false});
      await tester.tap(find.text('点了 0 次'));
      await tester.pump();
      expect(find.text('点了 1 次'), findsOneWidget);

      await tester.pumpWidget(stack(MeowTab.home, probes));
      expect(enabled, {MeowTab.home: true, MeowTab.connections: false, MeowTab.me: false});
      expect(find.text('点了 1 次'), findsNothing);
      expect(find.text('点了 1 次', skipOffstage: false), findsOneWidget);

      await tester.pumpWidget(stack(MeowTab.proxies, probes));
      expect(find.text('点了 1 次'), findsOneWidget);
    });
  });

  group('KeyboardInset', () {
    const barHeight = 80.0;

    // 壳的两种形态。[stock] = 改之前：Scaffold 默认随键盘改 body 尺寸；否则 = 现在：Scaffold 不动，页面自己包 KeyboardInset。
    Widget shell({required bool wide, required bool stock, required Widget page, Widget? other}) {
      final wrapped = stock ? page : KeyboardInset(child: page);
      final content = Stack(children: [?other, wrapped]);
      return Scaffold(
        extendBody: !wide,
        resizeToAvoidBottomInset: stock,
        body: SafeArea(bottom: wide, child: content),
        bottomNavigationBar: wide ? null : const SizedBox(height: barHeight),
      );
    }

    // 系统给的 MediaQuery：导航条 24，键盘升到 [keyboard] 高（盖过导航条的那部分从 padding 里扣掉）
    Future<void> pump(WidgetTester tester, Widget child, {required double keyboard}) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const navBar = 24.0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewPadding: const EdgeInsets.only(top: 30, bottom: navBar),
              padding: EdgeInsets.only(top: 30, bottom: (navBar - keyboard).clamp(0, navBar)),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: child!,
          ),
          home: child,
        ),
      );
    }

    for (final wide in [false, true]) {
      testWidgets('${wide ? '宽屏（无底栏）' : '手机（悬浮底栏）'}：包了 KeyboardInset 的页面和 Scaffold 自己让键盘时排得一样', (tester) async {
        // 键盘从收起到完全升起，途经「没高过导航条」「没高过底栏」「刚好等于」「高过」
        for (final keyboard in [0.0, 10.0, 24.0, 50.0, barHeight - 1, barHeight, barHeight + 1, 180.0, 320.0]) {
          (BoxConstraints, MediaQueryData)? before, after;
          await pump(
            tester,
            shell(wide: wide, stock: true, page: _Probe((context, c) => before = (c, MediaQuery.of(context)))),
            keyboard: keyboard,
          );
          await pump(
            tester,
            shell(wide: wide, stock: false, page: _Probe((context, c) => after = (c, MediaQuery.of(context)))),
            keyboard: keyboard,
          );
          final reason = '键盘高 $keyboard';
          expect(after!.$1.biggest, before!.$1.biggest, reason: reason);
          expect(after!.$2.padding, before!.$2.padding, reason: reason);
          expect(after!.$2.viewInsets, before!.$2.viewInsets, reason: reason);
          expect(after!.$2.viewPadding, before!.$2.viewPadding, reason: reason);
        }
      });

      testWidgets('${wide ? '宽屏' : '手机'}：键盘升起时没包的页面不再跟着重排', (tester) async {
        for (final stock in [true, false]) {
          var layouts = 0;
          Size? size;
          final other = _Probe((_, c) {
            layouts++;
            size = c.biggest;
          });
          Widget build() => shell(wide: wide, stock: stock, page: const SizedBox.expand(), other: other);
          // 从键盘刚盖过系统导航条算起：盖过的那一下系统的 padding.bottom 归零，哪种写法都要排一次，不算在内
          await pump(tester, build(), keyboard: 30);
          final startSize = size;
          layouts = 0;
          for (final keyboard in [100.0, 200.0, 320.0]) {
            await pump(tester, build(), keyboard: keyboard);
          }
          if (stock) {
            // 改之前：键盘每高一点，页面就换一次高度
            expect(layouts, 3);
            expect(size!.height, lessThan(startSize!.height));
          } else {
            expect(layouts, 0);
            expect(size, startSize);
          }
        }
      });
    }
  });
}
