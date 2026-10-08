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

    /// 切页：这一帧只开要进来那一页的 Ticker，下一帧才换过去。
    Future<void> switchTo(WidgetTester tester, MeowTab tab, Widget Function(MeowTab) pageBuilder) async {
      await tester.pumpWidget(stack(tab, pageBuilder));
      await tester.pump();
    }

    /// 等离开的那一页过了宽限期、静音生效。
    Future<void> pastGrace(WidgetTester tester) async {
      await tester.pump(MeowTabStack.leaveGrace);
      await tester.pump();
    }

    testWidgets('隐藏页里的转圈不出帧：停在别的页时整个 App 是闲的', (tester) async {
      await tester.pumpWidget(stack(MeowTab.home, pages));
      await tester.pump();
      // 对照：不静音的话（裸 IndexedStack 就是这样）隐藏的转圈每一帧都在要下一帧
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.byType(CircularProgressIndicator, skipOffstage: false), findsOneWidget);

      // 切到它所在的页：开始转
      await switchTo(tester, MeowTab.connections, pages);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);

      // 切走：宽限期内还在转（收尾动画要靠这段时间播完），过了就停
      await switchTo(tester, MeowTab.me, pages);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await pastGrace(tester);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pump(const Duration(seconds: 3));
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

    testWidgets('Ticker 只给当前页、刚离开的页（宽限期内）开；四页都留在树上，切走再回来状态还在', (tester) async {
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

      // 切页的那一帧：要进来的页 Ticker 先开，画的还是原来那一页
      await tester.pumpWidget(stack(MeowTab.home, probes));
      expect(enabled, {MeowTab.home: true, MeowTab.connections: false, MeowTab.me: false});
      expect(find.text('点了 1 次'), findsOneWidget);
      expect(find.text(MeowTab.home.label), findsNothing);
      // 下一帧换过去
      await tester.pump();
      expect(find.text(MeowTab.home.label), findsOneWidget);
      expect(find.text('点了 1 次'), findsNothing);
      expect(find.text('点了 1 次', skipOffstage: false), findsOneWidget);

      // 再切到「我的」：首页刚离开，宽限期内 Ticker 还开着，到点才静音
      await switchTo(tester, MeowTab.me, probes);
      expect(enabled, {MeowTab.home: true, MeowTab.connections: false, MeowTab.me: true});
      await tester.pump(MeowTabStack.leaveGrace - const Duration(milliseconds: 100));
      expect(enabled[MeowTab.home], isTrue);
      await pastGrace(tester);
      expect(enabled, {MeowTab.home: false, MeowTab.connections: false, MeowTab.me: true});

      await switchTo(tester, MeowTab.proxies, probes);
      expect(find.text('点了 1 次'), findsOneWidget);
    });

    testWidgets('宽限期内来回切：最后离开的那一页到点静音，当前页不受影响', (tester) async {
      final enabled = <MeowTab, bool>{};
      Widget probes(MeowTab t) => Builder(
        builder: (context) {
          enabled[t] = TickerMode.valuesOf(context).enabled;
          return Text(t.label);
        },
      );
      await tester.pumpWidget(stack(MeowTab.home, probes));
      await switchTo(tester, MeowTab.proxies, probes);
      await tester.pump(const Duration(milliseconds: 300));
      // 首页的宽限期还没完就切回首页：轮到节点页留宽限期，旧的那只定时器不能把首页静音掉
      await switchTo(tester, MeowTab.home, probes);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(enabled[MeowTab.home], isTrue);
      expect(enabled[MeowTab.proxies], isTrue);
      await pastGrace(tester);
      expect(enabled, {MeowTab.home: true, MeowTab.proxies: false, MeowTab.connections: false, MeowTab.me: false});
      expect(find.text(MeowTab.home.label), findsOneWidget);
    });

    // 首页一张底色随 [on] 过渡的卡（连接主卡就是这样的 AnimatedContainer）
    const cardKey = ValueKey('card');
    const offColor = Color(0xFF101010), onColor = Color(0xFFE0E0E0);
    Widget Function(MeowTab) card({required bool on}) =>
        (t) => t == MeowTab.home
        ? AnimatedContainer(
            key: cardKey,
            duration: const Duration(milliseconds: 200),
            color: on ? onColor : offColor,
            width: 100,
            height: 100,
          )
        : Text(t.label);
    Color cardColor(WidgetTester tester) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(cardKey, skipOffstage: false),
          matching: find.byType(DecoratedBox, skipOffstage: false),
          skipOffstage: false,
        ),
      );
      return (box.decoration as BoxDecoration).color!;
    }

    testWidgets('隐藏期间才开始的过渡：切回来露面的那一帧已经是终态，不先闪一帧旧样子', (tester) async {
      await tester.pumpWidget(stack(MeowTab.home, card(on: false)));
      await switchTo(tester, MeowTab.proxies, card(on: false));
      await pastGrace(tester);
      // 停在节点页时状态变了（宽屏：点侧栏电源键连上）：首页已静音，过渡走不动
      await tester.pumpWidget(stack(MeowTab.proxies, card(on: true)));
      await tester.pump(const Duration(seconds: 2));
      expect(cardColor(tester), offColor);

      // 切回首页的那一帧：Ticker 刚打开还没走，画的仍是节点页
      await tester.pumpWidget(stack(MeowTab.home, card(on: true)));
      expect(find.byKey(cardKey), findsNothing);
      expect(find.text(MeowTab.proxies.label), findsOneWidget);
      // 下一帧首页露面，过渡已经追到终态
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(cardKey), findsOneWidget);
      expect(cardColor(tester), onColor);
    });

    testWidgets('离开那一刻还在播的动画：宽限期内在后台播完', (tester) async {
      await tester.pumpWidget(stack(MeowTab.home, card(on: false)));
      // 状态刚变（过渡开始）就切走
      await tester.pumpWidget(stack(MeowTab.home, card(on: true)));
      await tester.pump(const Duration(milliseconds: 16));
      await switchTo(tester, MeowTab.proxies, card(on: true));
      expect(cardColor(tester), isNot(onColor));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      expect(cardColor(tester), onColor);
    });

    // 气泡画在根 Overlay 上（页面隐藏了它照样画），但它的 element 挂在所在页下面：隐藏页里的要 skipOffstage: false 才找得到
    final bubble = find.text('测速全部', skipOffstage: false);

    testWidgets('提示气泡不会留在别的页上：不经触摸切页（系统返回键回首页）时也收掉', (tester) async {
      Widget tips(MeowTab t) => t == MeowTab.proxies
          ? const Center(child: Tooltip(message: '测速全部', child: SizedBox(width: 60, height: 60)))
          : Text(t.label);
      await tester.pumpWidget(stack(MeowTab.proxies, tips));
      // 长按出气泡，松手后它默认再留 1.5 秒
      final press = await tester.startGesture(tester.getCenter(find.byType(Tooltip)));
      await tester.pump(const Duration(milliseconds: 700));
      await press.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(bubble, findsOneWidget);

      await switchTo(tester, MeowTab.home, tips);
      // 淡出 75ms，在宽限期内走完
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(bubble, findsNothing);
      await pastGrace(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(bubble, findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('对照：隐藏页当场静音的话（改之前的写法），气泡一直留在别的页上', (tester) async {
      Widget app(MeowTab current) => MaterialApp(
        home: Scaffold(
          body: IndexedStack(
            index: current.index,
            children: [
              for (final t in MeowTab.values)
                TickerMode(
                  enabled: t == current,
                  child: t == MeowTab.proxies
                      ? const Center(child: Tooltip(message: '测速全部', child: SizedBox(width: 60, height: 60)))
                      : Text(t.label),
                ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(app(MeowTab.proxies));
      final press = await tester.startGesture(tester.getCenter(find.byType(Tooltip)));
      await tester.pump(const Duration(milliseconds: 700));
      await press.up();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(app(MeowTab.home));
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(bubble, findsOneWidget);
    });

    testWidgets('气泡刚弹出、还没走过一帧就切页：不在 build 期间摘 Overlay', (tester) async {
      Widget tips(MeowTab t) => t == MeowTab.proxies
          ? const Center(
              child: Tooltip(message: '测速全部', triggerMode: TooltipTriggerMode.tap, child: SizedBox(width: 60, height: 60)),
            )
          : Text(t.label);
      await tester.pumpWidget(stack(MeowTab.proxies, tips));
      // 点按即弹：淡入刚开始、值还是 0，这时收它是当场把浮层摘掉
      await tester.tap(find.byType(Tooltip));
      await switchTo(tester, MeowTab.home, tips);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(bubble, findsNothing);
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
