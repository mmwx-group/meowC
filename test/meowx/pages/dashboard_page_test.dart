import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/dashboard/active_connections_card.dart';
import 'package:bett_box/meowx/pages/dashboard/dashboard_page.dart';
import 'package:bett_box/meowx/pages/dashboard/info_cards.dart';
import 'package:bett_box/meowx/pages/dashboard/speed_card.dart';
import 'package:bett_box/meowx/pages/dashboard/takeover_card.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/exit_ip.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 各 Notifier 换成不碰 globalState / 核心 / 网络的替身，页面本身的布局与交互保持真实。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Patch extends PatchClashConfig {
  _Patch(this.mode);
  final Mode mode;

  @override
  ClashConfig build() => ClashConfig(mode: mode);

  @override
  void onUpdate(ClashConfig value) {}
}

class _Vpn extends VpnSetting {
  _Vpn(this.access);
  final AccessControl access;

  @override
  VpnProps build() => VpnProps(accessControl: access);

  @override
  void onUpdate(VpnProps value) {}
}

class _RunTime extends RunTime {
  _RunTime(this.initial);
  final int? initial;

  @override
  int? build() => initial;

  @override
  void onUpdate(int? value) {}
}

class _Traffics extends Traffics {
  @override
  FixedList<Traffic> build() => FixedList(
    60,
    list: [for (var i = 0; i < 40; i++) Traffic(up: 1024 * (200 + i * 7 % 90), down: 1024 * 1024 * (1 + i % 5))],
  );

  @override
  void onUpdate(FixedList<Traffic> value) {}
}

class _TotalTraffic extends TotalTraffic {
  @override
  Traffic build() => Traffic(up: 90386381, down: 1524713390);

  @override
  void onUpdate(Traffic value) {}
}

class _Profiles extends Profiles {
  _Profiles(this.initial);
  final List<Profile> initial;

  @override
  List<Profile> build() => initial;

  @override
  void onUpdate(List<Profile> value) {}
}

class _ProfileId extends CurrentProfileId {
  _ProfileId(this.initial);
  final String? initial;

  @override
  String? build() => initial;

  @override
  void onUpdate(String? value) {}
}

class _CheckIpNum extends CheckIpNum {
  @override
  int build() => 0;

  @override
  void onUpdate(int value) {}
}

class _ExitIp extends ExitIpController {
  _ExitIp(this.initial);
  final ExitIpState initial;
  int refreshes = 0;

  @override
  ExitIpState build() => initial;

  @override
  Future<void> refresh({required bool running}) async => refreshes++;

  @override
  void clearGlobal() {}
}

class _Stats extends ConnStatsController {
  @override
  ConnStats build() => const ConnStats(total: 64, proxied: 23, direct: 41, memory: 60817408);
}

final _profile = Profile(
  id: 'p1',
  label: '妙妙屋 · 主力订阅（名字特别长的那种套餐，用来挤一挤右边的用量）',
  url: 'https://example.com/sub',
  lastUpdateDate: DateTime.now().subtract(const Duration(hours: 3)),
  autoUpdateDuration: const Duration(days: 1),
  subscriptionInfo: const SubscriptionInfo(upload: 1073741824 * 8, download: 129278519706, total: 1073741824 * 500, expire: 1798718400),
);

TrackerInfo _conn(int i, String host, String via, {String type = 'Tun'}) => TrackerInfo(
  id: '$i',
  download: 1024 * 1024 * i,
  start: DateTime(2026, 10, 7, 14, 0, i),
  metadata: Metadata(network: 'tcp', host: host, destinationPort: '443', type: type),
  chains: [via],
  rule: 'MATCH',
  rulePayload: '',
);

final _conns = [
  _conn(1, 'www.youtube.com', '🇭🇰 香港 01 · IEPL'),
  _conn(2, 'api.telegram.org', '新加坡 01'),
  _conn(3, 'chatgpt.com', '洛杉矶 01 · 9929', type: 'HTTP'),
  _conn(4, 'a-very-long-subdomain.of.some.really-long-host-name.api.bilibili.com', 'DIRECT'),
  _conn(5, 'github.com', '香港 01 · IEPL', type: 'Socks5'),
  _conn(6, 'steamcdn-a.akamaihd.net', 'DIRECT'),
  _conn(7, 'weixin.qq.com', 'DIRECT'),
  _conn(8, 'registry.npmjs.org', '东京 01 · IIJ', type: 'HTTP'),
  _conn(9, 'discord.com', '东京 01 · IIJ'),
];

const _node = CurrentNode(group: '节点选择', path: ['节点选择', '自动选择'], leaf: '🇭🇰 香港 01 · IEPL 专线（名字很长很长很长的节点）');

List<Override> _overrides({
  required bool running,
  bool wide = false,
  bool twoPane = false,
  Mode mode = Mode.rule,
  List<String> hidden = const [],
  Profile? profile,
  CurrentNode? node = _node,
  AccessControl access = const AccessControl(),
  _ExitIp? exitIp,
}) => [
  isRunningProvider.overrideWithValue(running),
  isWideLayoutProvider.overrideWithValue(wide),
  isTwoPaneProvider.overrideWithValue(twoPane),
  connPhaseProvider.overrideWithValue(running ? ConnPhase.on : ConnPhase.off),
  powerEnabledProvider.overrideWithValue(profile != null),
  hasProfileProvider.overrideWithValue(profile != null),
  currentNodeProvider.overrideWithValue(node),
  currentNodeDelayProvider.overrideWithValue(node == null ? null : 38),
  declaredDnsModeProvider.overrideWithValue('fake-ip'),
  tunEnabledProvider.overrideWithValue(true),
  systemProxyEnabledProvider.overrideWithValue(false),
  tunHintProvider.overrideWithValue(('接管全部应用的流量 · 服务已就绪', false)),
  currentProfileProvider.overrideWithValue(profile),
  meowSettingProvider.overrideWith(() => _Meow(MeowSettings(homeHiddenCards: hidden))),
  patchClashConfigProvider.overrideWith(() => _Patch(mode)),
  vpnSettingProvider.overrideWith(() => _Vpn(access)),
  runTimeProvider.overrideWith(() => _RunTime(running ? 8076000 : null)),
  trafficsProvider.overrideWith(_Traffics.new),
  totalTrafficProvider.overrideWith(_TotalTraffic.new),
  profilesProvider.overrideWith(() => _Profiles([?profile])),
  currentProfileIdProvider.overrideWith(() => _ProfileId(profile?.id)),
  checkIpNumProvider.overrideWith(_CheckIpNum.new),
  connStatsProvider.overrideWith(_Stats.new),
  exitIpProvider.overrideWith(
    () =>
        exitIp ??
        _ExitIp(
          running
              ? ExitIpState(
                  domestic: IpInfo(ip: '2408:8207:1234:5678:9abc:def0:1234:5678', countryCode: 'CN'),
                  global: IpInfo(ip: '198.51.100.7', countryCode: 'HK'),
                  globalVia: '🇭🇰 香港 01 · IEPL',
                )
              : ExitIpState(domestic: IpInfo(ip: '203.0.113.24', countryCode: 'CN')),
        ),
  ),
];

/// 按给定窗口尺寸与文字缩放摆出来（溢出、intrinsic 断言都会作为异常让用例失败）。
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required Size size,
  required List<Override> overrides,
  double textScale = 1.4,
  double bottomInset = 0,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // 收掉页面里的定时器（出口 IP 的延迟重查）
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  // 同一个用例里换一组 override 再摆一次：先拆掉上一棵，ProviderScope 才会按新的 override 重建
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

DashboardPage _page() => DashboardPage(fetchConnections: () async => _conns);

void main() {
  testWidgets('手机 · 已连接：窄屏 1.4 倍字号不溢出；主卡 / 当前节点 / 网速 / 订阅 / 指标 / 出口 IP', (tester) async {
    await _pump(
      tester,
      _page(),
      size: const Size(320, 1400),
      overrides: _overrides(running: true, profile: _profile),
      bottomInset: 96,
    );

    expect(find.text('MeowX'), findsOneWidget);
    expect(find.text('规则模式 · 核心运行中'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('已运行 02:14:36'), findsOneWidget);
    // 当前节点：国旗换成地区码，路径是组链
    expect(find.text('香港 01 · IEPL 专线（名字很长很长很长的节点）'), findsOneWidget);
    expect(find.text('节点选择 › 自动选择'), findsOneWidget);
    expect(find.text('38 ms'), findsOneWidget);
    expect(find.text('上传 · 会话 86.2 MB'), findsOneWidget);
    expect(find.text('下载 · 会话 1.42 GB'), findsOneWidget);
    expect(find.text('128.4 / 500 GB'), findsOneWidget);
    expect(find.text('到期 2026-12-31'), findsOneWidget);
    expect(find.text('3 小时前更新'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.text('41'), findsOneWidget);
    expect(find.text('58.0 MB'), findsOneWidget);
    expect(find.text('Fake-IP'), findsOneWidget);
    expect(find.text('国际 · 经 香港 01 · IEPL'), findsOneWidget);
    expect(find.text('198.51.100.7'), findsOneWidget);
    // 长的 IPv6 折成两行完整显示
    expect(find.text('2408:8207:1234:5678:\n9abc:def0:1234:5678'), findsOneWidget);
    // 手机端没有「活跃连接」「接管方式」
    expect(find.byType(HomeActiveConnections), findsNothing);
    expect(find.byType(HomeTakeoverCard), findsNothing);
    // 悬浮底栏的高度让进了列表底部留白
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.padding, const EdgeInsets.fromLTRB(16, 0, 16, 16 + 96));
  });

  testWidgets('手机 · 未连接 / 没有订阅 / 深色', (tester) async {
    await _pump(
      tester,
      _page(),
      size: const Size(412, 892),
      overrides: _overrides(running: false, node: null),
      textScale: 1,
      brightness: Brightness.dark,
    );

    expect(find.text('未连接'), findsWidgets);
    expect(find.text('未配置'), findsOneWidget);
    expect(find.text('先到「我的」导入订阅'), findsOneWidget);
    expect(find.text('没有代理组'), findsOneWidget);
    expect(find.text('还没有订阅'), findsOneWidget);
    expect(find.text('国际 · 代理出口'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);   // 内存
  });

  testWidgets('直连模式：当前节点行给直连文案，不画地区码和延迟', (tester) async {
    await _pump(
      tester,
      _page(),
      size: const Size(412, 892),
      overrides: _overrides(running: true, profile: _profile, mode: Mode.direct),
      textScale: 1,
    );

    expect(find.text('直连模式 · 核心运行中'), findsOneWidget);
    expect(find.text('全部流量不经过代理'), findsOneWidget);
    expect(find.text('38 ms'), findsNothing);
  });

  testWidgets('首页卡片开关：关掉的格子 / 列 / 折线不出现，出口 IP 关掉后不查也没有重查钮', (tester) async {
    final exitIp = _ExitIp(const ExitIpState());
    await _pump(
      tester,
      _page(),
      size: const Size(412, 892),
      overrides: _overrides(
        running: true,
        profile: _profile,
        hidden: const ['upload', 'chart', 'direct', 'memory', 'ip'],
        exitIp: exitIp,
      ),
      textScale: 1,
    );

    expect(find.textContaining('上传 · 会话'), findsNothing);
    expect(find.textContaining('下载 · 会话'), findsOneWidget);
    expect(find.text('代理连接'), findsOneWidget);
    expect(find.text('直连连接'), findsNothing);
    expect(find.text('内存'), findsNothing);
    expect(find.text('Fake-IP'), findsOneWidget);
    expect(find.byType(HomeExitIp), findsNothing);
    expect(find.byTooltip('重新查询出口 IP'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(exitIp.refreshes, 0);

    // 网速三项全关：整张网速卡不出现（Windows 上折线恒在，卡还在）
    await _pump(
      tester,
      _page(),
      size: const Size(412, 892),
      overrides: _overrides(running: true, profile: _profile, hidden: const ['upload', 'download', 'chart']),
      textScale: 1,
    );
    expect(find.byType(HomeSpeedCard), isDesktopUi ? findsOneWidget : findsNothing);
  });

  testWidgets('标题行的重查钮立即重查出口 IP', (tester) async {
    final exitIp = _ExitIp(const ExitIpState());
    await _pump(
      tester,
      _page(),
      size: const Size(412, 892),
      overrides: _overrides(running: true, profile: _profile, exitIp: exitIp),
      textScale: 1,
    );
    final before = exitIp.refreshes;   // 进页面那一次
    await tester.tap(find.byTooltip('重新查询出口 IP'));
    expect(exitIp.refreshes, before + 1);
  });

  testWidgets('两列 · 够高：整页一屏不滚动，「活跃连接」撑满右列', (tester) async {
    // 1100×720 的窗口去掉标题栏与完整侧栏后的内容区
    await _pump(
      tester,
      _page(),
      size: const Size(868, 680),
      overrides: _overrides(running: true, wide: true, twoPane: true, profile: _profile, hidden: const ['chart']),
      textScale: 1,
    );

    expect(find.text('首页'), findsOneWidget);
    expect(find.text('活跃连接'), findsOneWidget);
    expect(find.text('查看全部 64 条'), findsOneWidget);
    expect(find.text('核心内存'), findsOneWidget);
    expect(find.text('DNS · 跟随订阅'), findsOneWidget);
    // 最近建立的排最前
    expect(find.text('discord.com:443'), findsOneWidget);
    expect(find.text('SOCKS'), findsOneWidget);
    // 一屏放得下：不能滚
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.maxScrollExtent, 0);
    // 卡片底边贴着内容区底部留白
    final card = tester.getRect(find.byType(HomeActiveConnections));
    expect(card.bottom, closeTo(680 - 16, 0.5));

    // 第二次快照才有速率（相邻两次的下载字节差）
    expect(find.text('0 KB/s'), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    dashboardRefreshManager.tick1s.value++;   // 测试里没有起每秒节拍的定时器，手动推一下
    await tester.pump();
    await tester.pump();
    expect(find.text('0 KB/s'), findsWidgets);
  });

  testWidgets('两列 · 不够高（矮窗口、1.4 倍字号）：按内容高度排、整页滚动，不溢出', (tester) async {
    await _pump(
      tester,
      _page(),
      size: const Size(800, 440),
      overrides: _overrides(running: true, wide: true, twoPane: true, profile: _profile),
    );

    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    expect(find.text('活跃连接'), findsOneWidget);
    // 手机横屏那种更矮的也一样
    await _pump(
      tester,
      _page(),
      size: const Size(800, 380),
      overrides: _overrides(running: false, wide: true, twoPane: true),
    );
    expect(find.text('未连接'), findsWidgets);
  });

  testWidgets('有侧栏的单列（700–899 宽）', (tester) async {
    await _pump(
      tester,
      _page(),
      size: const Size(600, 1500),
      overrides: _overrides(running: true, wide: true, profile: _profile),
    );

    expect(find.text('首页'), findsOneWidget);
    expect(find.text('活跃连接'), findsOneWidget);
    expect(find.text('discord.com:443'), findsOneWidget);
    // 固定排 5 行
    expect(find.text('github.com:443'), findsOneWidget);
    expect(find.text('a-very-long-subdomain.of.some.really-long-host-name.api.bilibili.com:443'), findsNothing);
  });

  testWidgets('接管方式卡（Windows）：窄列大字号不溢出', (tester) async {
    await _pump(
      tester,
      const Align(alignment: Alignment.topLeft, child: SizedBox(width: 300, child: HomeTakeoverCard())),
      size: const Size(400, 400),
      overrides: _overrides(running: true),
    );

    expect(find.text('接管方式'), findsOneWidget);
    expect(find.text('接管全部应用的流量 · 服务已就绪'), findsOneWidget);
    expect(find.text('127.0.0.1:7890'), findsOneWidget);
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect([for (final s in switches) s.value], [true, false]);
  });

  testWidgets('代理应用入口（Android）：摘要跟着分应用代理的设置走', (tester) async {
    Future<void> pump(AccessControl access) => _pump(
      tester,
      const Align(alignment: Alignment.topLeft, child: SizedBox(width: 288, child: HomeProxyAppsRow())),
      size: const Size(320, 300),
      overrides: _overrides(running: true, access: access),
    );

    await pump(const AccessControl());
    expect(find.text('全部应用都走代理'), findsOneWidget);

    await pump(const AccessControl(enable: true, mode: AccessControlMode.acceptSelected, acceptList: ['a', 'b', 'c']));
    expect(find.text('白名单 · 只代理选中的 3 个应用'), findsOneWidget);

    await pump(const AccessControl(enable: true, rejectList: ['a', 'b']));
    expect(find.text('黑名单 · 选中的 2 个应用不走代理'), findsOneWidget);
  });
}
