import 'package:bett_box/common/common.dart';
import 'package:bett_box/meowx/pages/settings/wifi_switch_page.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/wifi_switch.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 「我的 › Wi-Fi 智能开关」页：MeowX 设置与 Bettbox 的 VPN 设置换成不落盘的替身，网络状态直接给定。
// 测试跑在宿主机上（不是 Android），页面不去调原生插件，权限一行停在「读取中…」。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Vpn extends VpnSetting {
  @override
  VpnProps build() => const VpnProps(smartAutoStop: true);

  @override
  void onUpdate(VpnProps value) {}
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  MeowSettings meow = const MeowSettings(),
  WifiSwitchStatus status = const WifiSwitchStatus(),
  bool paused = false,
}) async {
  const size = Size(360, 1000);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
      overrides: [
        meowSettingProvider.overrideWith(() => _Meow(meow)),
        vpnSettingProvider.overrideWith(_Vpn.new),
        wifiSwitchStatusProvider.overrideWith((ref) => status),
        wifiPausedProvider.overrideWithValue(paused),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: const WifiSwitchPage(),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(WifiSwitchPage)));
}

void main() {
  testWidgets('打开总开关：写进设置，并关掉高级里的「智能启停」；没有规则时给出说明', (tester) async {
    final c = await _pump(tester);
    // VPN 设置是 autoDispose：挂个监听，不然改完读回来是重建的初始值
    c.listen(vpnSettingProvider, (_, _) {});
    expect(find.textContaining('点右上角「+」添加'), findsOneWidget);
    expect(find.text('当前网络'), findsNothing);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(c.read(meowSettingProvider).wifiSwitchEnabled, isTrue);
    expect(c.read(vpnSettingProvider).smartAutoStop, isFalse);
    expect(find.text('当前网络'), findsOneWidget);
  });

  testWidgets('当前网络、已暂停、规则行；一键添加当前 Wi-Fi（1.4 倍字号窄屏不溢出）', (tester) async {
    final c = await _pump(
      tester,
      meow: const MeowSettings(
        wifiSwitchEnabled: true,
        wifiRules: [MeowWifiRule(ssid: 'Home'), MeowWifiRule(ssid: 'Office', action: MeowWifiAction.connect)],
      ),
      status: const WifiSwitchStatus(snapshot: NetSnapshot(NetKind.wifi, ssid: 'Cafe')),
      paused: true,
    );
    expect(find.text('Wi-Fi「Cafe」'), findsOneWidget);
    expect(find.text('代理已暂停'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('断开代理'), findsOneWidget);
    expect(find.text('连接代理'), findsWidgets);
    expect(find.text('定位权限'), findsOneWidget);

    await tester.tap(find.text('添加当前 Wi-Fi「Cafe」'));
    await tester.pumpAndSettle();
    expect(find.text('添加 Wi-Fi 规则'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Cafe'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    expect(c.read(meowSettingProvider).wifiRules.map((r) => (r.ssid, r.action)), [
      ('Home', MeowWifiAction.disconnect),
      ('Office', MeowWifiAction.connect),
      ('Cafe', MeowWifiAction.disconnect),
    ]);
    expect(find.textContaining('添加当前 Wi-Fi'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('读不到 Wi-Fi 名称时把原因写出来', (tester) async {
    await _pump(
      tester,
      meow: const MeowSettings(wifiSwitchEnabled: true, wifiRules: [MeowWifiRule(ssid: 'Home')]),
      status: const WifiSwitchStatus(
        snapshot: NetSnapshot(NetKind.wifi, issue: SsidIssue.background),
        note: '定位权限不是「始终允许」，App 在后台时读不到 Wi-Fi 名称，这次不切换',
      ),
    );
    expect(find.text('Wi-Fi（读不到名称）'), findsOneWidget);
    expect(find.textContaining('这次不切换'), findsOneWidget);
  });

  testWidgets('删除与编辑规则；改名撞上已有的并成一条', (tester) async {
    final c = await _pump(
      tester,
      meow: const MeowSettings(
        wifiSwitchEnabled: true,
        wifiRules: [MeowWifiRule(ssid: 'Home'), MeowWifiRule(ssid: 'Office', action: MeowWifiAction.connect)],
      ),
    );
    await tester.tap(find.text('Office'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' Home ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(c.read(meowSettingProvider).wifiRules, [const MeowWifiRule(ssid: 'Home', action: MeowWifiAction.connect)]);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(c.read(meowSettingProvider).wifiRules, isEmpty);
  });

  test('入口摘要', () {
    expect(wifiSwitchSummary(const MeowSettings(), paused: false), '未开启');
    expect(wifiSwitchSummary(const MeowSettings(wifiSwitchEnabled: true), paused: false), '没有规则');
    expect(
      wifiSwitchSummary(const MeowSettings(wifiSwitchEnabled: true, wifiRules: [MeowWifiRule(ssid: 'A')]), paused: true),
      '1 条规则 · 已暂停',
    );
  });
}
