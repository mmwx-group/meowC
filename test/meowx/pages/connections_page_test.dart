import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/pages/connections/connections_page.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/page_title.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _conn(String id, String host, List<String> chains, {String network = 'tcp', String rule = 'GEOSITE', String payload = ''}) => TrackerInfo(
  id: id,
  upload: 1800000,
  download: 46200000,
  start: DateTime.now().subtract(const Duration(seconds: 42)),
  metadata: Metadata(network: network, host: host, destinationIP: '198.51.100.44', destinationPort: '443', type: 'Tun', inboundName: 'DEFAULT-TUN'),
  chains: chains,
  rule: rule,
  rulePayload: payload,
);

final _conns = [
  _conn('1', 'www.youtube.com', ['香港 01 · IEPL', '自动选择', '节点选择'], payload: 'youtube'),
  _conn('2', 'api.telegram.org', ['新加坡 01', '节点选择'], network: 'udp', rule: 'RULE-SET', payload: 'telegram'),
  _conn('3', 'a-very-long-subdomain.of.some.really-long-host-name.api.bilibili.com', ['DIRECT'], payload: 'cn'),
];

class _TestAppSetting extends AppSetting {
  @override
  AppSettingProps build() => const AppSettingProps(openLogs: true);

  @override
  void onUpdate(AppSettingProps value) {}
}

class _TestLogs extends Logs {
  _TestLogs([this.initial]);

  /// 不给就是下面那三条
  final List<Log>? initial;

  @override
  FixedList<Log> build() => FixedList(
    maxLength,
    list: [
      ...initial ??
          const [
            Log(logLevel: LogLevel.info, payload: '[TCP] www.youtube.com:443 → 香港 01 · IEPL 命中 GEOSITE,youtube', dateTime: '2026-10-07 14:02:36'),
            Log(logLevel: LogLevel.warning, payload: '节点 伦敦 01 测速超时，已从 自动选择 中暂时移除', dateTime: '2026-10-07 14:02:31'),
            Log(logLevel: LogLevel.error, payload: 'dns: 解析 example.invalid 失败：NXDOMAIN', dateTime: '2026-10-07 14:01:58'),
          ],
    ],
  );

  @override
  void onUpdate(FixedList<Log> value) {}
}

/// 假的核心（不注入 fetch、让页面走默认取数时用）：记两种取法各被问了几次。
class _Source extends ConnSource {
  int lists = 0, countCalls = 0;

  @override
  Future<List<TrackerInfo>> list() async {
    lists++;
    return _conns;
  }

  @override
  Future<ConnCounts> counts() async {
    countCalls++;
    return countConnections(_conns);
  }
}

/// 按给定窗口尺寸与文字缩放把页面摆出来（溢出会作为异常让用例失败）。
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required bool wide,
  required bool twoPane,
  bool running = true,
  double textScale = 1.4,
  double bottomInset = 0,
  MeowTab tab = MeowTab.connections,
  List<Log>? logs,
  Future<List<TrackerInfo>> Function()? fetch,
  ConnSource? source,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // 收掉页面里的轮询定时器
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isRunningProvider.overrideWithValue(running),
        isWideLayoutProvider.overrideWithValue(wide),
        isTwoPaneProvider.overrideWithValue(twoPane),
        meowTabProvider.overrideWith((ref) => tab),
        appSettingProvider.overrideWith(_TestAppSetting.new),
        logsProvider.overrideWith(() => _TestLogs(logs)),
        if (source != null) connSourceProvider.overrideWithValue(source),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: child!,
        ),
        // 给了 source = 不注入 fetch，页面走默认取数（经壳的 ConnStatsController）
        home: Scaffold(body: ConnectionsPage(fetch: source != null ? null : (fetch ?? () async => _conns))),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(ConnectionsPage)));

/// 日志列表的滚动位置（页面里搜索框自己也带一个 Scrollable）。
ScrollPosition _logScroll(WidgetTester tester) =>
    tester.state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable))).position;

void main() {
  testWidgets('手机：标题 / 分段 / 汇总 / 连接行，1.4 倍字号不溢出；点行弹出详情', (tester) async {
    await _pump(tester, size: const Size(360, 780), wide: false, twoPane: false, bottomInset: 96);

    expect(find.text('动态'), findsOneWidget);
    expect(find.text('连接 · 3'), findsOneWidget);
    expect(find.text('3 条 · 代理 2 · 直连 1'), findsOneWidget);
    expect(find.text('www.youtube.com:443'), findsOneWidget);
    expect(find.text('全部关闭'), findsOneWidget);
    // 悬浮底栏的高度让进了列表底部留白
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.padding, const EdgeInsets.only(bottom: 16 + 96));

    await tester.tap(find.text('www.youtube.com:443'));
    await tester.pumpAndSettle();
    expect(find.text('出站链路'), findsOneWidget);
    expect(find.text('节点选择 › 自动选择 › 香港 01 · IEPL'), findsOneWidget);
    expect(find.text('GEOSITE(youtube)'), findsWidgets);
    expect(find.text('TUN · DEFAULT-TUN'), findsOneWidget);
    expect(find.text('关闭这条连接'), findsOneWidget);
  });

  testWidgets('搜索按主机 / 出站 / 规则筛选，汇总跟着变；切分段清空搜索', (tester) async {
    await _pump(tester, size: const Size(412, 892), wide: false, twoPane: false, textScale: 1);

    await tester.enterText(find.byType(TextField), 'telegram');
    await tester.pump();
    expect(find.text('1 条 · 代理 1 · 直连 0'), findsOneWidget);
    expect(find.text('www.youtube.com:443'), findsNothing);

    await tester.enterText(find.byType(TextField), 'no-such-host');
    await tester.pump();
    expect(find.text('无匹配连接'), findsOneWidget);

    await tester.tap(find.text('日志'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.textContaining('NXDOMAIN'), findsOneWidget);
  });

  testWidgets('日志：级别 / 时间 / 消息，搜索与清空', (tester) async {
    await _pump(tester, size: const Size(360, 780), wide: false, twoPane: false);

    await tester.tap(find.text('日志'));
    await tester.pump();
    expect(find.text('记录日志已开启 · 自动滚动到底'), findsOneWidget);
    expect(find.textContaining('14:02:36', findRichText: true), findsOneWidget);

    await tester.enterText(find.byType(TextField), '伦敦');
    await tester.pump();
    expect(find.text('1 条匹配'), findsOneWidget);
    expect(find.textContaining('NXDOMAIN'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(find.text('暂无日志'), findsOneWidget);
  });

  testWidgets('两栏：连接表 + 右侧汇总 / 详情，窄窗口大字号不溢出', (tester) async {
    // 900 宽窗口去掉收起的侧栏后的内容区
    await _pump(tester, size: const Size(760, 560), wide: true, twoPane: true);

    expect(find.text('主机'), findsOneWidget);
    expect(find.text('出站'), findsOneWidget);
    expect(find.text('活动连接'), findsOneWidget);
    expect(find.text('3 条 · 代理 2 · 直连 1'), findsOneWidget);

    await tester.tap(find.text('www.youtube.com:443'));
    await tester.pump();
    expect(find.text('活动连接'), findsNothing);
    expect(find.text('命中规则'), findsOneWidget);
    expect(find.text('关闭这条连接'), findsOneWidget);

    // 再点一次取消选中
    await tester.tap(find.text('www.youtube.com:443').first);
    await tester.pump();
    expect(find.text('活动连接'), findsOneWidget);

    await tester.tap(find.text('日志'));
    await tester.pump();
    expect(find.text('全部关闭'), findsNothing);
    expect(find.textContaining('NXDOMAIN'), findsOneWidget);
  });

  testWidgets('平板竖屏（有侧栏、单列）与未连接', (tester) async {
    await _pump(tester, size: const Size(580, 900), wide: true, twoPane: false);
    expect(find.text('3 条 · 代理 2 · 直连 1'), findsOneWidget);

    await _pump(tester, size: const Size(360, 780), wide: false, twoPane: false, running: false);
    expect(find.text('隧道未连接'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
  });

  testWidgets('轮询只重建列表那几块：标题、搜索框不动；分段只在条数变了时重建', (tester) async {
    var round = 0;
    final rounds = [
      _conns,
      [_conns[0], _conns[1], _conn('4', 'github.com', ['DIRECT'])],
      [_conns[0]],
    ];
    await _pump(
      tester,
      size: const Size(412, 892),
      wide: false,
      twoPane: false,
      textScale: 1,
      fetch: () async => rounds[round < rounds.length ? round++ : rounds.length - 1],
    );
    expect(find.text('连接 · 3'), findsOneWidget);
    final title = tester.widget(find.byType(PageTitle));
    final field = tester.widget(find.byType(TextField));
    final segment = tester.widget(find.byWidgetPredicate((w) => w is MeowSegment));

    // 下一拍：同样 3 条，其中一条换了
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('github.com:443'), findsOneWidget);
    expect(find.text('3 条 · 代理 2 · 直连 1'), findsOneWidget);
    expect(tester.widget(find.byType(PageTitle)), same(title));
    expect(tester.widget(find.byType(TextField)), same(field));
    expect(tester.widget(find.byWidgetPredicate((w) => w is MeowSegment)), same(segment));

    // 再下一拍：只剩 1 条，分段上的条数跟着变
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('连接 · 1'), findsOneWidget);
    expect(find.text('1 条 · 代理 1 · 直连 0'), findsOneWidget);
    expect(tester.widget(find.byType(PageTitle)), same(title));
    expect(tester.widget(find.byType(TextField)), same(field));
  });

  testWidgets('App 退到后台 / 窗口收进托盘不取数，旧快照留着；回到前台立即补一次', (tester) async {
    var fetches = 0;
    addTearDown(() => globalState.backgroundMode.value = false);
    await _pump(
      tester,
      size: const Size(412, 892),
      wide: false,
      twoPane: false,
      textScale: 1,
      fetch: () async {
        fetches++;
        return _conns;
      },
    );
    expect(fetches, 1);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(fetches, 2);

    globalState.backgroundMode.value = true;
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(fetches, 2);
    expect(find.text('3 条 · 代理 2 · 直连 1'), findsOneWidget);

    globalState.backgroundMode.value = false;
    await tester.pump();
    expect(fetches, 3);
  });

  testWidgets('被别的 Tab 盖着：不取数，也不画「加载中」的转圈；切回来先转圈、拿到快照出列表', (tester) async {
    final gate = Completer<List<TrackerInfo>>();
    var fetches = 0;
    await _pump(
      tester,
      size: const Size(412, 892),
      wide: false,
      twoPane: false,
      textScale: 1,
      tab: MeowTab.home,
      fetch: () {
        fetches++;
        return gate.future;
      },
    );
    await tester.pump(const Duration(milliseconds: 1500));
    expect(fetches, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    _container(tester).read(meowTabProvider.notifier).state = MeowTab.connections;
    await tester.pump();
    expect(fetches, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete(_conns);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('连接 · 3'), findsOneWidget);

    // 再切走：转圈不留在隐藏页里
    _container(tester).read(meowTabProvider.notifier).state = MeowTab.me;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('默认取数经壳：这份快照顺手更新连接计数，壳不再另拉', (tester) async {
    final source = _Source();
    // 平板竖屏：有侧栏（角标要连接数，壳在每一页都轮询）
    await _pump(tester, size: const Size(580, 900), wide: true, twoPane: false, textScale: 1, source: source);

    expect(find.text('连接 · 3'), findsOneWidget);
    final stats = _container(tester).read(connStatsProvider);
    expect((stats.total, stats.proxied, stats.direct), (3, 2, 1));
    expect(source.lists, 1);

    // 壳每秒的那一拍：动态页刚取过完整快照，不再自己问核心
    dashboardRefreshManager.tick1s.value++;
    await tester.pump();
    expect(source.countCalls, 0);
    expect(source.lists, 1);
  });

  testWidgets('日志：密的时候合并着刷；贴着底才跟到底，往上翻时不被拽回去；被别的 Tab 盖着不刷', (tester) async {
    await _pump(
      tester,
      size: const Size(360, 780),
      wide: false,
      twoPane: false,
      textScale: 1,
      logs: [
        for (var i = 0; i < 60; i++)
          Log(logLevel: LogLevel.info, payload: '[TCP] host-$i.example.com:443 → 香港 01 命中 MATCH', dateTime: '2026-10-07 14:00:${i.toString().padLeft(2, '0')}'),
      ],
    );
    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    final logs = _container(tester).read(logsProvider.notifier);
    Log line(String text) => Log(logLevel: LogLevel.warning, payload: text, dateTime: '2026-10-07 14:05:00');

    // 进来就在底部
    final pos = _logScroll(tester);
    expect(pos.maxScrollExtent, greaterThan(0));
    expect(pos.pixels, pos.maxScrollExtent);
    expect(find.textContaining('host-59.'), findsOneWidget);

    // 贴着底：新日志立刻出现并跟到底
    logs.addLog(line('新来的第一条'));
    await tester.pumpAndSettle();
    expect(find.text('新来的第一条'), findsOneWidget);
    expect(pos.pixels, pos.maxScrollExtent);

    // 紧跟着来的几条攒到 250ms 一起刷
    logs.addLog(line('紧跟着的第二条'));
    logs.addLog(line('紧跟着的第三条'));
    await tester.pump();
    await tester.pump();
    expect(find.text('紧跟着的第三条'), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('紧跟着的第三条'), findsOneWidget);
    expect(pos.pixels, pos.maxScrollExtent);

    // 往上翻着看旧日志：再来新的不动位置
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    final reading = pos.pixels;
    expect(reading, lessThan(pos.maxScrollExtent - 100));
    logs.addLog(line('翻看时来的'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(pos.pixels, reading);

    // 被别的 Tab 盖着：不重建；切回来补上
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('翻看时来的'), findsOneWidget);
    _container(tester).read(meowTabProvider.notifier).state = MeowTab.home;
    await tester.pump();
    logs.addLog(line('盖着的时候来的'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('盖着的时候来的'), findsNothing);
    _container(tester).read(meowTabProvider.notifier).state = MeowTab.connections;
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('盖着的时候来的'), findsOneWidget);
  });
}
