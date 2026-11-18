import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/advanced/config/core_config_page.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/theme/motion.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 各 Notifier 换成不碰 globalState.config 落盘的替身；页面本身的布局与交互保持真实。

class _Patch extends PatchClashConfig {
  _Patch(this.initial);
  final ClashConfig initial;

  @override
  ClashConfig build() => initial;

  @override
  void onUpdate(ClashConfig value) {}
}

class _App extends AppSetting {
  @override
  AppSettingProps build() => const AppSettingProps();

  @override
  void onUpdate(AppSettingProps value) {}
}

class _Vpn extends VpnSetting {
  @override
  VpnProps build() => const VpnProps();

  @override
  void onUpdate(VpnProps value) {}
}

class _Network extends NetworkSetting {
  @override
  NetworkProps build() => const NetworkProps();

  @override
  void onUpdate(NetworkProps value) {}
}

class _OvDns extends OverrideDns {
  @override
  bool build() => false;

  @override
  void onUpdate(bool value) {}
}

class _OvNtp extends OverrideNtp {
  @override
  bool build() => false;

  @override
  void onUpdate(bool value) {}
}

class _OvSniffer extends OverrideSniffer {
  @override
  bool build() => false;

  @override
  void onUpdate(bool value) {}
}

class _OvExperimental extends OverrideExperimental {
  @override
  bool build() => false;

  @override
  void onUpdate(bool value) {}
}

class _OvTestUrl extends OverrideTestUrl {
  @override
  bool build() => false;

  @override
  void onUpdate(bool value) {}
}

List<Override> _overrides({ClashConfig config = const ClashConfig()}) => [
  patchClashConfigProvider.overrideWith(() => _Patch(config)),
  appSettingProvider.overrideWith(_App.new),
  vpnSettingProvider.overrideWith(_Vpn.new),
  networkSettingProvider.overrideWith(_Network.new),
  overrideDnsProvider.overrideWith(_OvDns.new),
  overrideNtpProvider.overrideWith(_OvNtp.new),
  overrideSnifferProvider.overrideWith(_OvSniffer.new),
  overrideExperimentalProvider.overrideWith(_OvExperimental.new),
  overrideTestUrlProvider.overrideWith(_OvTestUrl.new),
  // macOS 上跑测试时网络页有「自动设置系统 DNS」：它读内核运行状态，这里给定值
  autoSetSystemDnsStateProvider.overrideWithValue(const VM2(a: false, b: false)),
];

/// 窄屏（360 宽）+ 1.4 倍字号摆出来；溢出会作为异常让用例失败。
Future<void> _pump(WidgetTester tester, {List<Override>? overrides, double height = 2400}) async {
  final size = Size(360, height);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // BaseNavigator.push 按视口宽度选转场
  globalState.appState = AppState(
    viewSize: size,
    brightness: Brightness.light,
    version: 0,
    requests: FixedList(1),
    logs: FixedList(1),
    traffics: FixedList(1),
    totalTraffic: Traffic(),
    systemUiOverlayStyle: const SystemUiOverlayStyle(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides ?? _overrides(),
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: const CoreConfigPage(),
      ),
    ),
  );
  await tester.pump();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(CoreConfigPage, skipOffstage: false)));

/// 点入口行进子页，等转场播完。
Future<void> _open(WidgetTester tester, String entry) async {
  final row = find.widgetWithText(MeRow, entry).first;
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

Future<void> _tapRow(WidgetTester tester, String label) async {
  final row = find.widgetWithText(MeRow, label).last;
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

/// 选项行：点开菜单、点某一项（菜单项先亮选中块，menuAutoClose 之后才关、回传）。
Future<void> _pick(WidgetTester tester, String label, String item) async {
  await _tapRow(tester, label);
  await tester.tap(find.text(item).last);
  await tester.pump(MeowMotion.menuAutoClose);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('首页：窄屏 1.4 倍字号不溢出；各分组入口与 NTP / 实验性都在', (tester) async {
    await _pump(tester);
    for (final label in ['通用', '网络', 'DNS', 'Hosts', '域名嗅探', '流量转发隧道', '覆写 NTP', '覆写实验性配置']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // 写入系统只在非安卓显示（测试跑在桌面）
    expect(find.text('写入系统'), findsOneWidget);
  });

  testWidgets('首页：NTP 覆写、实验性开关、NTP 服务器选项写进 provider', (tester) async {
    await _pump(tester);
    final c = _container(tester);

    await _tapRow(tester, '覆写 NTP');
    expect(c.read(overrideNtpProvider), isTrue);

    // 缺省开着，点一下关掉
    await _tapRow(tester, '禁用 QUIC 通用分段卸载');
    expect(c.read(patchClashConfigProvider).experimental.quicGoDisableGso, isFalse);

    await _pick(tester, '服务器', 'ntp.aliyun.com');
    expect(c.read(patchClashConfigProvider).ntp.server, 'ntp.aliyun.com');

    // 重置：确认后整段 ntp 回到默认值
    await _tapRow(tester, '重置 NTP');
    await tester.tap(find.widgetWithText(FilledButton, '重置'));
    await tester.pumpAndSettle();
    expect(c.read(patchClashConfigProvider).ntp, defaultNtp);
  });

  testWidgets('通用：不溢出；IPv6 开关、日志等级选项写进 provider', (tester) async {
    await _pump(tester);
    await _open(tester, '通用');
    expect(find.text('日志等级'), findsOneWidget);
    final c = _container(tester);

    await _tapRow(tester, 'IPv6');
    expect(c.read(patchClashConfigProvider).ipv6, isTrue);

    await _tapRow(tester, '查找进程');
    expect(c.read(patchClashConfigProvider).findProcessMode, FindProcessMode.always);

    await _pick(tester, '日志等级', 'debug');
    expect(c.read(patchClashConfigProvider).logLevel, LogLevel.debug);
  });

  testWidgets('通用：端口对话框校验（超范围不提交）、合法值写入', (tester) async {
    await _pump(tester);
    await _open(tester, '通用');
    final c = _container(tester);
    await _tapRow(tester, '端口');
    final field = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextFormField)).first;
    await tester.enterText(field, '80');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1024 到 49151'), findsOneWidget);
    expect(c.read(patchClashConfigProvider).mixedPort, 7890);
    await tester.enterText(field, '7891');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(c.read(patchClashConfigProvider).mixedPort, 7891);
  });

  testWidgets('DNS：不溢出；Fallback 并发取反写入、DNS 模式选项、域名服务器列表添加', (tester) async {
    await _pump(tester);
    await _open(tester, 'DNS');
    final c = _container(tester);
    // 直连域名服务器为空时不显示「直连 DNS 遵循规则」
    expect(find.text('直连 DNS 遵循规则'), findsNothing);

    await _tapRow(tester, '覆写 DNS');
    expect(c.read(overrideDnsProvider), isTrue);

    // 缺省 fallback-lazy-query = false → 界面显示开；点一下 = lazy 变 true
    await _tapRow(tester, 'Fallback 并发');
    expect(c.read(patchClashConfigProvider).dns.fallbackLazyQuery, isTrue);

    await _pick(tester, 'DNS 模式', 'redirHost');
    expect(c.read(patchClashConfigProvider).dns.enhancedMode, DnsMode.redirHost);

    // 域名服务器列表：添加一条；重复值不让加
    await _tapRow(tester, '域名服务器');
    expect(find.text('1.1.1.1'), findsOneWidget);
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    final input = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextFormField));
    await tester.enterText(input, '1.1.1.1');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('值当前已存在'), findsOneWidget);
    await tester.enterText(input, '8.8.8.8');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(c.read(patchClashConfigProvider).dns.nameserver, ['1.1.1.1', '8.8.8.8']);

    // 删除
    await tester.tap(find.byTooltip('删除').first);
    await tester.pumpAndSettle();
    expect(c.read(patchClashConfigProvider).dns.nameserver, ['8.8.8.8']);
  });

  testWidgets('网络 / 嗅探 / 转发 / Hosts：不溢出；系统代理开关写进 provider', (tester) async {
    await _pump(tester);
    final c = _container(tester);
    await _open(tester, '网络');
    expect(find.text('栈模式'), findsOneWidget);
    await _tapRow(tester, '系统代理');
    expect(c.read(networkSettingProvider).systemProxy, isTrue);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    await _open(tester, '域名嗅探');
    expect(find.text('HTTP 端口嗅探'), findsOneWidget);
    await _tapRow(tester, '解析纯 IP 连接'); // 缺省开着
    expect(c.read(patchClashConfigProvider).sniffer.parsePureIp, isFalse);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    await _open(tester, '流量转发隧道');
    expect(find.textContaining('暂无数据'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    await _open(tester, 'Hosts');
    expect(find.textContaining('暂无数据'), findsOneWidget);
  });
}
