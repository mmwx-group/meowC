import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/app/meow_sidebar.dart';
import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/node_count.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/release_frames.dart';

// 各 Notifier 换成不碰 globalState / 核心的替身，侧栏本身的布局保持真实。

class _Patch extends PatchClashConfig {
  @override
  ClashConfig build() => const ClashConfig(mode: Mode.rule);

  @override
  void onUpdate(ClashConfig value) {}
}

class _RunTime extends RunTime {
  @override
  int? build() => 8076000;

  @override
  void onUpdate(int? value) {}
}

class _Stats extends ConnStatsController {
  _Stats(this.total);
  final int total;

  @override
  ConnStats build() => ConnStats(total: total);

  void setTotal(int value) => state = ConnStats(total: value);
}

Future<ProviderContainer> _pump(WidgetTester tester, {required bool compact, int nodes = 128, int conns = 64}) async {
  tester.view.physicalSize = const Size(1100, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connPhaseProvider.overrideWithValue(ConnPhase.on),
        powerEnabledProvider.overrideWithValue(true),
        hasProfileProvider.overrideWithValue(true),
        currentNodeProvider.overrideWithValue(const CurrentNode(group: '节点选择', path: ['节点选择'], leaf: '🇭🇰 香港 01')),
        patchClashConfigProvider.overrideWith(_Patch.new),
        runTimeProvider.overrideWith(_RunTime.new),
        leafNodeCountProvider.overrideWithValue(nodes),
        connStatsProvider.overrideWith(() => _Stats(conns)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            children: [MeowSidebar(selected: MeowTab.home, onSelect: (_) {}, compact: compact)],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(MeowSidebar)));
}

void main() {
  testWidgets('完整形态：「节点」「动态」带计数角标，连接数变了角标跟着变', (tester) async {
    final container = await _pump(tester, compact: false);
    expect(find.text('节点'), findsOneWidget);
    expect(find.text('128'), findsOneWidget);
    expect(find.text('64'), findsOneWidget);
    expect(find.text('规则模式 · 02:14:36'), findsOneWidget);

    (container.read(connStatsProvider.notifier) as _Stats).setTotal(65);
    await tester.pump();
    expect(find.text('65'), findsOneWidget);
    expect(find.text('64'), findsNothing);
    expect(find.text('128'), findsOneWidget);
  });

  testWidgets('完整形态：运行时长按秒跳；同一秒里的第二次写入（两路在写）不重建', (tester) async {
    final container = await _pump(tester, compact: false);
    useReleaseProviderFrames();
    await tester.pump();

    container.read(runTimeProvider.notifier).value = 8076900;
    await expectNoFrameRequested(tester);

    container.read(runTimeProvider.notifier).value = 8077000;
    await tester.pump();
    expect(find.text('规则模式 · 02:14:37'), findsOneWidget);
  });

  testWidgets('完整形态：计数为 0 不画角标，超过 999 写成 999+', (tester) async {
    await _pump(tester, compact: false, nodes: 0, conns: 1234);
    expect(find.text('0'), findsNothing);
    expect(find.text('999+'), findsOneWidget);
  });

  testWidgets('紧凑形态：没有角标，连接数怎么变都不重建、不要帧', (tester) async {
    final container = await _pump(tester, compact: true);
    expect(find.text('节点'), findsNothing);
    expect(find.text('128'), findsNothing);
    expect(find.text('64'), findsNothing);
    expect(find.byTooltip('节点'), findsOneWidget);

    useReleaseProviderFrames();
    await tester.pump();
    for (final total in [65, 66, 67]) {
      (container.read(connStatsProvider.notifier) as _Stats).setTotal(total);
      await expectNoFrameRequested(tester, reason: '连接数 $total');
    }
  });
}
