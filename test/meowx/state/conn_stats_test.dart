import 'dart:async';
import 'dart:convert';

import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _conn(String id, String via) => TrackerInfo(
  id: id,
  start: DateTime(2026, 10, 7, 14),
  metadata: const Metadata(network: 'tcp', host: 'example.com', destinationPort: '443'),
  chains: [via, '节点选择'],
  rule: 'MATCH',
  rulePayload: '',
);

/// 假的核心：记两种取法各被问了几次。
class _Source extends ConnSource {
  _Source(this.conns);
  List<TrackerInfo> conns;
  int lists = 0, countCalls = 0;

  /// 不为 null 时 list() 卡在这上面（模拟快照还在路上）
  Completer<void>? gate;

  @override
  Future<List<TrackerInfo>> list() async {
    lists++;
    await gate?.future;
    return conns;
  }

  @override
  Future<ConnCounts> counts() async {
    countCalls++;
    return countConnections(conns);
  }
}

final _running = StateProvider<bool>((ref) => true);

/// 壳的那套装配：计数 provider 被常驻 listen 着；[notified] 记通知次数。
class _Shell {
  _Shell({required bool wide, required MeowTab tab, List<TrackerInfo>? conns})
    : source = _Source(conns ?? [_conn('1', '香港 01'), _conn('2', '香港 01'), _conn('3', 'DIRECT')]) {
    container = ProviderContainer(
      overrides: [
        isRunningProvider.overrideWith((ref) => ref.watch(_running)),
        isWideLayoutProvider.overrideWithValue(wide),
        meowTabProvider.overrideWith((ref) => tab),
        connSourceProvider.overrideWithValue(source),
      ],
    );
    addTearDown(container.dispose);
    container.listen(connStatsProvider, (_, _) => notified++);
  }

  final _Source source;
  late final ProviderContainer container;
  int notified = 0;

  ConnStats get stats => container.read(connStatsProvider);
  ConnStatsController get controller => container.read(connStatsProvider.notifier);

  /// 推一下每秒节拍（测试里没有起那个定时器），等这一拍的取数落地。
  Future<void> tick() async {
    dashboardRefreshManager.tick1s.value++;
    await pumpEventQueue();
  }

  Future<void> goTab(MeowTab tab) async {
    container.read(meowTabProvider.notifier).state = tab;
    await pumpEventQueue();
  }
}

void main() {
  test('手机布局：不在首页不问核心；切回首页立即补一次', () async {
    final s = _Shell(wide: false, tab: MeowTab.proxies);
    await s.tick();
    await s.tick();
    expect(s.source.countCalls, 0);
    expect(s.source.lists, 0);
    expect(s.stats.total, 0);

    await s.goTab(MeowTab.home);
    expect(s.source.countCalls, 1);
    expect((s.stats.total, s.stats.proxied, s.stats.direct), (3, 2, 1));

    await s.tick();
    expect(s.source.countCalls, 2);

    await s.goTab(MeowTab.me);
    await s.tick();
    expect(s.source.countCalls, 2);
    // 离开期间保留最后一次的数，不清零
    expect(s.stats.total, 3);
  });

  test('宽屏：侧栏角标每一页都在，任何 Tab 都拉；壳自己只要三个计数，不取完整列表', () async {
    final s = _Shell(wide: true, tab: MeowTab.me);
    await s.tick();
    expect(s.source.countCalls, 1);
    expect(s.source.lists, 0);
    expect((s.stats.total, s.stats.proxied, s.stats.direct), (3, 2, 1));

    // 一直在拉，切回首页不用额外补
    await s.goTab(MeowTab.home);
    expect(s.source.countCalls, 1);
  });

  test('可见页面取完整快照：计数顺手更新，壳在这之后 1.6s 内不再自己问核心', () async {
    final s = _Shell(wide: true, tab: MeowTab.connections);
    var now = DateTime(2026, 10, 7, 14);
    s.controller.now = () => now;

    final list = await s.controller.fetchConnections();
    expect(list, hasLength(3));
    expect((s.stats.total, s.stats.proxied, s.stats.direct), (3, 2, 1));

    // 动态页 1.5s 取一次，壳每秒的那一拍都落在窗口里
    now = now.add(const Duration(milliseconds: 1000));
    await s.tick();
    now = now.add(const Duration(milliseconds: 500));
    await s.tick();
    expect(s.source.countCalls, 0);

    // 页面不取了（切走 / 退后台）：过了窗口壳接手
    now = now.add(const Duration(milliseconds: 200));
    await s.tick();
    expect(s.source.countCalls, 1);

    // 系统时钟往回拨：按过期算，不会从此不拉
    await s.controller.fetchConnections();
    now = now.subtract(const Duration(hours: 1));
    await s.tick();
    expect(s.source.countCalls, 2);
  });

  test('页面的快照还在路上：壳这一拍不重复取', () async {
    final s = _Shell(wide: true, tab: MeowTab.home);
    s.source.gate = Completer<void>();
    final pending = s.controller.fetchConnections();
    await s.tick();
    await s.tick();
    expect(s.source.countCalls, 0);

    s.source.gate!.complete();
    expect(await pending, hasLength(3));
    expect(s.stats.total, 3);
  });

  test('数字没变不通知', () async {
    final s = _Shell(wide: true, tab: MeowTab.home);
    await s.tick();
    expect(s.notified, 1);
    await s.tick();
    await s.tick();
    expect(s.source.countCalls, 3);
    expect(s.notified, 1);

    s.source.conns = [...s.source.conns, _conn('4', 'DIRECT')];
    await s.tick();
    expect(s.notified, 2);
    expect((s.stats.total, s.stats.proxied, s.stats.direct), (4, 2, 2));
  });

  test('核心停了：清零，不问核心', () async {
    final s = _Shell(wide: true, tab: MeowTab.home);
    await s.tick();
    expect(s.stats.total, 3);

    s.container.read(_running.notifier).state = false;
    await s.tick();
    expect(s.source.countCalls, 1);
    expect((s.stats.total, s.stats.proxied, s.stats.direct), (0, 0, 0));
  });

  test('计数口径：直接数快照 JSON 与数建好的列表一致', () {
    final conns = [
      _conn('1', '香港 01'),
      _conn('2', 'DIRECT'),
      _conn('3', 'REJECT'),
      _conn('4', 'REJECT-DROP'),
      _conn('5', '🇯🇵 东京 01'),
      _conn('6', 'DIRECT').copyWith(chains: const []),
    ];
    final fromList = countConnections(conns);
    // REJECT 两边都不记；chains 为空的那条与原口径一样记在代理里
    expect(fromList, (total: 6, proxied: 3, direct: 1));
    expect(countConnectionsJson(json.encode({'connections': conns})), fromList);

    expect(countConnectionsJson('{"connections":null}'), (total: 0, proxied: 0, direct: 0));
    expect(countConnectionsJson('{"downloadTotal":0,"uploadTotal":0}'), (total: 0, proxied: 0, direct: 0));
  });
}
