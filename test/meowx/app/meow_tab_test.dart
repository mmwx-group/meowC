import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/release_frames.dart';

void main() {
  test('四个 Tab 的顺序与名称', () {
    expect([for (final t in MeowTab.values) t.label], ['首页', '节点', '动态', '我的']);
  });

  test('Bettbox 页面标签映射：配置 / 工具都落到「我的」，非 Tab 页返回 null', () {
    expect(MeowTab.fromPageLabel(PageLabel.dashboard), MeowTab.home);
    expect(MeowTab.fromPageLabel(PageLabel.proxies), MeowTab.proxies);
    expect(MeowTab.fromPageLabel(PageLabel.connections), MeowTab.connections);
    expect(MeowTab.fromPageLabel(PageLabel.profiles), MeowTab.me);
    expect(MeowTab.fromPageLabel(PageLabel.tools), MeowTab.me);
    expect(MeowTab.fromPageLabel(PageLabel.logs), isNull);
  });

  testWidgets('watchOnTab：不在那一页时不跟着数据重建、也不要帧，切回来那一帧拿到最新值', (tester) async {
    var builds = 0;
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              builds++;
              return Text('第 ${r.watchOnTab(MeowTab.home, _ticks)} 秒');
            },
          ),
        ),
      ),
    );
    expect(builds, 1);
    useReleaseProviderFrames();
    final container = ProviderScope.containerOf(tester.element(find.byType(Consumer)));
    // 和 Bettbox 的控制器一样：每次都现 read(notifier) 再写
    void tick(int v) => container.read(_ticks.notifier).value = v;

    // 在首页：照常跟
    tick(1);
    await tester.pump();
    expect(find.text('第 1 秒'), findsOneWidget);
    expect(builds, 2);

    // 切走：重建一次（可见性变了）
    ref.read(meowTabProvider.notifier).state = MeowTab.proxies;
    await tester.pump();
    await tester.pump();
    expect(builds, 3);
    // 之后数据怎么变都不重建，也没有任何东西要帧（autoDispose 的 provider 没被回收重建，值一直攒着）
    for (var i = 2; i <= 5; i++) {
      tick(i);
      await expectNoFrameRequested(tester, reason: '第 $i 次写入');
      await tester.pump();
    }
    expect(builds, 3);
    expect(find.text('第 1 秒'), findsOneWidget);
    expect(_ticksBuilt, 1);

    // 在别的页之间切换也不重建
    ref.read(meowTabProvider.notifier).state = MeowTab.me;
    await tester.pump();
    expect(builds, 3);

    // 切回来：同一帧里就是最新值，之后继续跟
    ref.read(meowTabProvider.notifier).state = MeowTab.home;
    await tester.pump();
    expect(find.text('第 5 秒'), findsOneWidget);
    expect(builds, 4);
    tick(6);
    await tester.pump();
    expect(find.text('第 6 秒'), findsOneWidget);
  });
}

var _ticksBuilt = 0;

class _Ticks extends AutoDisposeNotifier<int> {
  @override
  int build() {
    _ticksBuilt++;
    return 0;
  }

  set value(int v) => state = v;
}

/// 和 Bettbox 的状态 provider 同一种：autoDispose 的 Notifier。
final _ticks = NotifierProvider.autoDispose<_Ticks, int>(_Ticks.new);
