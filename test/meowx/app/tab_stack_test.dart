import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/app/tab_stack.dart';
import 'package:bett_box/meowx/theme/motion.dart';
import 'package:bett_box/meowx/theme/page_background.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
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

/// 每画一次回调一次。
class _PaintCounter extends CustomPainter {
  _PaintCounter(this.onPaint);
  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

void main() {
  group('MeowTabStack', () {
    Widget stack(MeowTab current, Widget Function(MeowTab) pageBuilder) => MaterialApp(
      home: Scaffold(
        body: MeowTabStack(current: current, pageBuilder: pageBuilder),
      ),
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
      // 下一帧开始平推：两页同时在画面上，推完只剩新页
      await tester.pump();
      expect(find.text(MeowTab.home.label), findsOneWidget);
      expect(find.text('点了 1 次'), findsOneWidget);
      await tester.pump(MeowMotion.tabSlide);
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
          ? const Center(
              child: Tooltip(message: '测速全部', child: SizedBox(width: 60, height: 60)),
            )
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
                      ? const Center(
                          child: Tooltip(message: '测速全部', child: SizedBox(width: 60, height: 60)),
                        )
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
              child: Tooltip(
                message: '测速全部',
                triggerMode: TooltipTriggerMode.tap,
                child: SizedBox(width: 60, height: 60),
              ),
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

  group('MeowTabStack 平推', () {
    const width = 400.0;
    Key pageKey(MeowTab t) => ValueKey('page-${t.name}');
    Widget pages(MeowTab t) => SizedBox.expand(key: pageKey(t), child: Text(t.label));

    Widget stack(MeowTab current, {bool reduce = false}) => MaterialApp(
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
        child: c!,
      ),
      home: Scaffold(
        body: MeowTabStack(current: current, pageBuilder: pages),
      ),
    );

    Future<void> setUpView(WidgetTester tester) async {
      tester.view.physicalSize = const Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    /// 页在画面上的左边（页宽 = 视口宽）；不在画面上为 null。
    double? x(WidgetTester tester, MeowTab t) {
      final f = find.byKey(pageKey(t));
      return f.evaluate().isEmpty ? null : tester.getTopLeft(f).dx;
    }

    double eased(Duration d) =>
        MeowMotion.tabSlideCurve.transform(d.inMicroseconds / MeowMotion.tabSlide.inMicroseconds);

    /// 切页并走到平推的第一帧（t = 0）。
    Future<void> switchTo(WidgetTester tester, MeowTab tab, {bool reduce = false}) async {
      await tester.pumpWidget(stack(tab, reduce: reduce));
      await tester.pump();
    }

    testWidgets('往后切：新页从右侧整页推入，旧页往左退 30%；380ms 推完只剩新页', (tester) async {
      await setUpView(tester);
      await tester.pumpWidget(stack(MeowTab.home));
      await switchTo(tester, MeowTab.me);
      expect(x(tester, MeowTab.me), width);
      expect(x(tester, MeowTab.home), 0);

      const half = Duration(milliseconds: 190);
      await tester.pump(half);
      expect(x(tester, MeowTab.me), closeTo(width * (1 - eased(half)), 0.5));
      expect(x(tester, MeowTab.home), closeTo(-width * MeowMotion.tabParallax * eased(half), 0.5));
      expect(x(tester, MeowTab.proxies), isNull);

      await tester.pump(MeowMotion.tabSlide - half - const Duration(milliseconds: 10));
      expect(x(tester, MeowTab.home), isNotNull); // 还没推完
      await tester.pump(const Duration(milliseconds: 10));
      expect(x(tester, MeowTab.me), 0);
      expect(x(tester, MeowTab.home), isNull);
      await tester.pump(const Duration(milliseconds: 1)); // 控制器越过终点的下一帧报完成，之后不再要帧
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('往前切：方向相反——新页从左侧推入，旧页往右退', (tester) async {
      await setUpView(tester);
      await tester.pumpWidget(stack(MeowTab.connections));
      await switchTo(tester, MeowTab.proxies);
      expect(x(tester, MeowTab.proxies), -width);
      const t = Duration(milliseconds: 100);
      await tester.pump(t);
      expect(x(tester, MeowTab.proxies), closeTo(-width * (1 - eased(t)), 0.5));
      expect(x(tester, MeowTab.connections), closeTo(width * MeowMotion.tabParallax * eased(t), 0.5));
      await tester.pump(MeowMotion.tabSlide);
      expect(x(tester, MeowTab.proxies), 0);
      expect(x(tester, MeowTab.connections), isNull);
    });

    testWidgets('背景不动：页面底只在最外层画一份、各页透明；旧页淡出，新页压在旧页上面', (tester) async {
      await setUpView(tester);
      await tester.pumpWidget(stack(MeowTab.home));
      await switchTo(tester, MeowTab.proxies);
      const t = Duration(milliseconds: 120);
      await tester.pump(t);
      final bgs = find.descendant(of: find.byType(MeowTabStack), matching: find.byType(MeowBgBox));
      expect(bgs, findsOneWidget);
      final bg = tester.widget<MeowBgBox>(bgs);
      expect(bg.fill.color, MeowTokens.light.bg);
      // 底不跟着页面动
      expect(tester.getTopLeft(bgs).dx, 0);
      double opacity(MeowTab t) {
        final page = find.byKey(pageKey(t));
        expect(find.ancestor(of: page, matching: find.byType(MeowBgBox)), findsNothing);
        return tester.widget<Opacity>(find.ancestor(of: page, matching: find.byType(Opacity)).first).opacity;
      }

      expect(opacity(MeowTab.home), closeTo(1 - eased(t), 1e-6));
      expect(opacity(MeowTab.proxies), 1);
      // 点两页重叠的地方：命中的是新页
      final hit = tester.hitTestOnBinding(const Offset(width - 10, 10));
      final top = hit.path.map((e) => e.target).whereType<RenderObject>().map((r) => r.debugCreator.toString());
      expect(top.any((c) => c.contains('page-proxies')), isTrue);
      expect(top.any((c) => c.contains('page-home')), isFalse);
    });

    testWidgets('平推中又点了别的 Tab：各页从当时的位置接着走，新目标从右侧推入，推完只剩它', (tester) async {
      await setUpView(tester);
      await tester.pumpWidget(stack(MeowTab.home));
      await switchTo(tester, MeowTab.proxies);
      await tester.pump(const Duration(milliseconds: 150));
      final homeX = x(tester, MeowTab.home)!, proxiesX = x(tester, MeowTab.proxies)!;
      expect(proxiesX, inExclusiveRange(0, width));

      await switchTo(tester, MeowTab.me);
      // 接上的第一帧：画面上的两页一格没跳，新目标在右侧边外
      expect(x(tester, MeowTab.home), closeTo(homeX, 0.5));
      expect(x(tester, MeowTab.proxies), closeTo(proxiesX, 0.5));
      expect(x(tester, MeowTab.me), width);

      const t = Duration(milliseconds: 200);
      await tester.pump(t);
      expect(x(tester, MeowTab.me), closeTo(width * (1 - eased(t)), 0.5));
      // 起点与这一帧各取整一次到物理像素，误差至多两个半像素
      expect(x(tester, MeowTab.proxies), closeTo(proxiesX - width * MeowMotion.tabParallax * eased(t), 1));
      await tester.pump(MeowMotion.tabSlide);
      expect(x(tester, MeowTab.me), 0);
      expect(x(tester, MeowTab.home), isNull);
      expect(x(tester, MeowTab.proxies), isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('平推中往回点：原页从当时的位置回正，推到一半的页退回右侧', (tester) async {
      await setUpView(tester);
      await tester.pumpWidget(stack(MeowTab.home));
      await switchTo(tester, MeowTab.proxies);
      await tester.pump(const Duration(milliseconds: 150));
      final homeX = x(tester, MeowTab.home)!, proxiesX = x(tester, MeowTab.proxies)!;

      await switchTo(tester, MeowTab.home);
      expect(x(tester, MeowTab.home), closeTo(homeX, 0.5));
      expect(x(tester, MeowTab.proxies), closeTo(proxiesX, 0.5));
      const t = Duration(milliseconds: 200);
      await tester.pump(t);
      expect(x(tester, MeowTab.home), closeTo(homeX * (1 - eased(t)), 0.5));
      expect(x(tester, MeowTab.proxies), closeTo(proxiesX + (width - proxiesX) * eased(t), 0.5));
      await tester.pump(MeowMotion.tabSlide);
      expect(x(tester, MeowTab.home), 0);
      expect(x(tester, MeowTab.proxies), isNull);
    });

    testWidgets('系统「移除动画」：直接换页，不平推', (tester) async {
      await setUpView(tester);
      await tester.pumpWidget(stack(MeowTab.home, reduce: true));
      await switchTo(tester, MeowTab.me, reduce: true);
      expect(x(tester, MeowTab.me), 0);
      expect(x(tester, MeowTab.home), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('位移取整到物理像素：字的横向小数位置和静止时一样，平推不生出新字形', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      const w = 1080 / 2.625;
      await tester.pumpWidget(stack(MeowTab.home));
      await switchTo(tester, MeowTab.proxies);
      var unsnapped = 0;
      for (var ms = 0; ms < 380; ms += 23) {
        final t = Duration(milliseconds: ms);
        final x1 = x(tester, MeowTab.proxies)!, x0 = x(tester, MeowTab.home)!;
        for (final v in [x1, x0]) {
          expect(v * 2.625, closeTo((v * 2.625).roundToDouble(), 1e-6));
        }
        // 与不取整的位置差不到半个物理像素
        final exact = w * (1 - eased(t));
        expect(x1, closeTo(exact, 0.5 / 2.625 + 1e-9));
        if ((x1 - exact).abs() > 1e-6) unsnapped++;
        await tester.pump(const Duration(milliseconds: 23));
      }
      expect(unsnapped, greaterThan(0));
    });
  });

  group('MeowTabStack 预热', () {
    Key pageKey(MeowTab t) => ValueKey('page-${t.name}');

    testWidgets('启动后把没上过台的页逐个垫在当前页底下画几帧；第一次切过去不用现画', (tester) async {
      final paints = <MeowTab, int>{};
      final ticking = <MeowTab, bool>{};
      Widget pages(MeowTab t) => Builder(
        builder: (context) {
          ticking[t] = TickerMode.valuesOf(context).enabled;
          return SizedBox.expand(
            key: pageKey(t),
            child: CustomPaint(painter: _PaintCounter(() => paints[t] = (paints[t] ?? 0) + 1), child: Text(t.label)),
          );
        },
      );
      Widget stack(MeowTab current) => MaterialApp(
        home: Scaffold(
          body: MeowTabStack(current: current, pageBuilder: pages, prewarm: true),
        ),
      );
      final page = find.byKey(pageKey(MeowTab.proxies));
      bool semanticsExcluded(MeowTab t) => tester
          .widget<ExcludeSemantics>(
            find
                .ancestor(of: find.byKey(pageKey(t), skipOffstage: false), matching: find.byType(ExcludeSemantics))
                .first,
          )
          .excluding;

      await tester.pumpWidget(stack(MeowTab.home));
      expect(paints, {MeowTab.home: 1});
      await tester.pump(MeowTabStack.prewarmDelay - const Duration(milliseconds: 1));
      expect(page, findsNothing);

      // 到点：节点页上台，垫在首页底下——不开 Ticker、不进无障碍树、点不到它
      await tester.pump(const Duration(milliseconds: 1));
      expect(page, findsOneWidget);
      expect(paints[MeowTab.proxies], 1);
      expect(ticking[MeowTab.proxies], isFalse);
      expect(semanticsExcluded(MeowTab.proxies), isTrue);
      expect(semanticsExcluded(MeowTab.home), isFalse);
      final hit = tester.hitTestOnBinding(tester.getCenter(find.byType(MeowTabStack)));
      final creators = hit.path.map((e) => e.target).whereType<RenderObject>().map((r) => r.debugCreator.toString());
      expect(creators.any((c) => c.contains('page-home')), isTrue);
      expect(creators.any((c) => c.contains('page-proxies')), isFalse);
      // 连垫四帧，依次往右挪 0 / 2 / 4 / 6 个物理像素（只挪图层、不重画），下一帧撤掉
      final dpr = tester.view.devicePixelRatio;
      for (final px in [0, 2, 4, 6]) {
        expect(tester.getTopLeft(page).dx, closeTo(px / dpr, 1e-9));
        await tester.pump();
      }
      expect(page, findsNothing);
      expect(paints[MeowTab.proxies], 1);

      // 隔一会儿下一页，直到都画过；当前页一直没重画
      for (final t in [MeowTab.connections, MeowTab.me]) {
        await tester.pump(MeowTabStack.prewarmGap);
        for (var i = 0; i < 4; i++) {
          expect(find.byKey(pageKey(t)), findsOneWidget);
          await tester.pump();
        }
        expect(find.byKey(pageKey(t)), findsNothing);
      }
      await tester.pump(MeowTabStack.prewarmGap);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(paints, {MeowTab.home: 1, MeowTab.proxies: 1, MeowTab.connections: 1, MeowTab.me: 1});

      // 第一次切到节点页：平推一路都用预热时录好的图层，不再现画
      await tester.pumpWidget(stack(MeowTab.proxies));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(MeowMotion.tabSlide);
      expect(page, findsOneWidget);
      expect(paints[MeowTab.proxies], 1);
    });

    testWidgets('到点时正在切页：往后推，已经上过台的页不再垫', (tester) async {
      Widget pages(MeowTab t) => SizedBox.expand(key: pageKey(t), child: Text(t.label));
      Widget stack(MeowTab current) => MaterialApp(
        home: Scaffold(
          body: MeowTabStack(current: current, pageBuilder: pages, prewarm: true),
        ),
      );
      await tester.pumpWidget(stack(MeowTab.home));
      await tester.pump(MeowTabStack.prewarmDelay - const Duration(milliseconds: 100));
      await tester.pumpWidget(stack(MeowTab.connections));
      await tester.pump();
      // 平推途中到点：除了正在推的两页，没有别的页上台
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(pageKey(MeowTab.proxies)), findsNothing);
      expect(find.byKey(pageKey(MeowTab.me)), findsNothing);
      // 推完之后才垫：首页与动态页都上过台，只剩节点页和我的页
      final warmed = <MeowTab>[];
      void look() {
        for (final t in [MeowTab.home, MeowTab.proxies, MeowTab.me]) {
          if (find.byKey(pageKey(t)).evaluate().isNotEmpty) warmed.add(t);
        }
      }

      await tester.pump(MeowMotion.tabSlide);
      look();
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        look();
        await tester.pump(MeowTabStack.prewarmGap);
        look();
      }
      expect(warmed.toSet().toList(), [MeowTab.proxies, MeowTab.me]);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
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
