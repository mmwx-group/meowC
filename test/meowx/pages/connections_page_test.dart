import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/pages/connections/connections_page.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
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
  @override
  FixedList<Log> build() => FixedList(
    maxLength,
    list: [
      const Log(logLevel: LogLevel.info, payload: '[TCP] www.youtube.com:443 → 香港 01 · IEPL 命中 GEOSITE,youtube', dateTime: '2026-10-07 14:02:36'),
      const Log(logLevel: LogLevel.warning, payload: '节点 伦敦 01 测速超时，已从 自动选择 中暂时移除', dateTime: '2026-10-07 14:02:31'),
      const Log(logLevel: LogLevel.error, payload: 'dns: 解析 example.invalid 失败：NXDOMAIN', dateTime: '2026-10-07 14:01:58'),
    ],
  );

  @override
  void onUpdate(FixedList<Log> value) {}
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
        meowTabProvider.overrideWith((ref) => MeowTab.connections),
        appSettingProvider.overrideWith(_TestAppSetting.new),
        logsProvider.overrideWith(_TestLogs.new),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: child!,
        ),
        home: Scaffold(body: ConnectionsPage(fetch: () async => _conns)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

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
}
