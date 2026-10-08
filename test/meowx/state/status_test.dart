import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/release_frames.dart';

class _RunTime extends RunTime {
  @override
  int? build() => null;

  @override
  void onUpdate(int? value) {}
}

void main() {
  testWidgets('isRunningProvider：起停照常跟；运行时长每秒跳动不让它失效，不白出帧', (tester) async {
    var builds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [runTimeProvider.overrideWith(_RunTime.new)],
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(
            builder: (context, ref, _) {
              builds++;
              return Text(ref.watch(isRunningProvider) ? '已连接' : '未连接');
            },
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(Consumer)));
    expect(find.text('未连接'), findsOneWidget);

    container.read(runTimeProvider.notifier).value = 0;
    await tester.pump();
    expect(find.text('已连接'), findsOneWidget);
    expect(builds, 2);

    useReleaseProviderFrames();
    await tester.pump();
    for (var second = 1; second <= 3; second++) {
      container.read(runTimeProvider.notifier).value = second * 1000;
      // 整个 watch runTimeProvider 的话，这里每秒都会排一次「重算 isRunningProvider」
      await expectNoFrameRequested(tester, reason: '第 $second 秒');
      await tester.pump();
    }
    expect(builds, 2);

    container.read(runTimeProvider.notifier).value = null;
    // 摘掉 debug 钩子之后和 release 一样：先过一个微任务 Riverpod 才去要帧，所以这里要 pump 两下
    await tester.pump();
    await tester.pump();
    expect(find.text('未连接'), findsOneWidget);
    expect(builds, 3);
  });
}
