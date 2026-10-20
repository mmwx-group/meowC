import 'package:bett_box/common/common.dart';
import 'package:bett_box/meowx/pages/connections/conn_rule_card.dart';
import 'package:bett_box/meowx/pages/me/settings_rows.dart';
import 'package:bett_box/meowx/pages/settings/custom_rules_page.dart';
import 'package:bett_box/meowx/state/custom_rules.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 自定义规则的两个入口：动态页连接详情里的「这个域名走」与「我的 › 设置 › 自定义规则」。
// MeowX 设置换成不落盘的替身，主代理组直接给定。

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
  VpnProps build() => const VpnProps();

  @override
  void onUpdate(VpnProps value) {}
}

const _p = MeowRuleAction.proxy;

Future<void> _pump(WidgetTester tester, Widget child, {MeowSettings meow = const MeowSettings(), Size size = const Size(360, 900), double textScale = 1.4}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // mePush → BaseNavigator.push 按视口宽度选转场
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
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isRunningProvider.overrideWithValue(false),
        meowSettingProvider.overrideWith(() => _Meow(meow)),
        vpnSettingProvider.overrideWith(_Vpn.new),
        mainProxyGroupProvider.overrideWithValue('节点选择'),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

List<MeowCustomRule> _rules(WidgetTester tester, Type type) =>
    ProviderScope.containerOf(tester.element(find.byType(type).first)).read(meowSettingProvider).customRules;

void main() {
  testWidgets('连接详情：三个动作按钮（代理带组名），默认含子域名；已有规则显示出来、可删除；1.4 倍字号窄卡不溢出', (tester) async {
    await _pump(
      tester,
      const Center(child: SizedBox(width: 268, child: ConnRuleCard(host: 'WWW.YouTube.com', ip: '198.51.100.44'))),
    );
    expect(find.text('这个域名走'), findsOneWidget);
    expect(find.text('www.youtube.com'), findsOneWidget);
    expect(find.text('直连'), findsOneWidget);
    expect(find.text('代理（节点选择）'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.textContaining('当前规则'), findsNothing);

    // 默认含子域名
    await tester.tap(find.text('代理（节点选择）'));
    await tester.pumpAndSettle();
    expect(_rules(tester, ConnRuleCard), [const MeowCustomRule(value: 'www.youtube.com', match: MeowRuleMatch.suffix, action: _p)]);
    expect(find.text('当前规则：含子域名 www.youtube.com → 代理（节点选择）'), findsOneWidget);

    // 同一档再点别的动作：原位改，不新增
    await tester.tap(find.text('直连'));
    await tester.pumpAndSettle();
    expect(_rules(tester, ConnRuleCard), [const MeowCustomRule(value: 'www.youtube.com', match: MeowRuleMatch.suffix)]);

    // 仅此域名 + 拒绝：新加一条放最前，「当前规则」换成它
    await tester.tap(find.text('仅此域名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(_rules(tester, ConnRuleCard).map((r) => (r.match, r.action)), [
      (MeowRuleMatch.domain, MeowRuleAction.reject),
      (MeowRuleMatch.suffix, MeowRuleAction.direct),
    ]);
    expect(find.text('当前规则：仅此域名 www.youtube.com → 拒绝'), findsOneWidget);

    // 删除当前规则：下一条命中的接着显示
    await tester.tap(find.byTooltip('删除规则'));
    await tester.pumpAndSettle();
    expect(_rules(tester, ConnRuleCard), [const MeowCustomRule(value: 'www.youtube.com', match: MeowRuleMatch.suffix)]);
    expect(find.text('当前规则：含子域名 www.youtube.com → 直连'), findsOneWidget);
  });

  testWidgets('连接详情：父域名的规则也算「当前规则」；只有 IP 的连接按 IP 加（没有匹配方式可选）', (tester) async {
    await _pump(
      tester,
      const ConnRuleCard(host: 'mail.google.com', ip: ''),
      meow: const MeowSettings(customRules: [MeowCustomRule(value: 'google.com', action: _p)]),
    );
    expect(find.text('当前规则：含子域名 google.com → 代理（节点选择）'), findsOneWidget);

    await _pump(tester, const ConnRuleCard(host: '', ip: '2001:DB8::1'));
    expect(find.text('这个 IP 走'), findsOneWidget);
    expect(find.text('含子域名'), findsNothing);
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(_rules(tester, ConnRuleCard), [const MeowCustomRule(value: '2001:db8::1', match: MeowRuleMatch.ip, action: MeowRuleAction.reject)]);
    expect(find.text('当前规则：2001:db8::1 → 拒绝'), findsOneWidget);

    // 域名、IP 都没有：不显示
    await _pump(tester, const ConnRuleCard(host: '', ip: ''));
    expect(find.text('这个 IP 走'), findsNothing);
    expect(find.text('这个域名走'), findsNothing);
  });

  testWidgets('设置：入口行显示条数，进子页列出域名 / 匹配方式 / 动作；新增（链接规范化）、编辑、删除', (tester) async {
    const meow = MeowSettings(
      customRules: [
        MeowCustomRule(value: 'example.org', action: _p),
        MeowCustomRule(value: '1.2.3.4', match: MeowRuleMatch.ip, action: MeowRuleAction.reject),
      ],
    );
    await _pump(tester, const SingleChildScrollView(child: TrafficRows()), meow: meow);
    expect(find.text('自定义规则'), findsOneWidget);
    expect(find.text('2 条'), findsOneWidget);
    await tester.tap(find.text('自定义规则'));
    await tester.pumpAndSettle();

    expect(find.byType(CustomRulesPage), findsOneWidget);
    expect(find.text('example.org'), findsOneWidget);
    expect(find.text('含子域名 · 代理（节点选择）'), findsOneWidget);
    expect(find.text('1.2.3.4'), findsOneWidget);
    expect(find.text('IP · 拒绝'), findsOneWidget);
    expect(find.textContaining('2 / 1000'), findsOneWidget);

    // 新增：不合法 → 提示、不保存
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    expect(find.text('代理 = 走「节点选择」'), findsOneWidget);
    final field = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(field, '*.bad.example');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();
    expect(find.text(customRuleHostInvalidMessage), findsOneWidget);

    // 整条链接 → 域名；仅此域名 + 拒绝；新的放最前
    await tester.enterText(field, 'https://Ads.Example.com:8443/track?id=1');
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('仅此域名')));
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('拒绝')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(_rules(tester, CustomRulesPage).first, const MeowCustomRule(value: 'ads.example.com', match: MeowRuleMatch.domain, action: MeowRuleAction.reject));
    expect(find.text('仅此域名 · 拒绝'), findsOneWidget);

    // 编辑：点一条，改成直连
    await tester.tap(find.text('example.org'));
    await tester.pumpAndSettle();
    expect(find.text('编辑规则'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('直连')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(_rules(tester, CustomRulesPage)[1], const MeowCustomRule(value: 'example.org'));
    expect(find.text('含子域名 · 直连'), findsOneWidget);

    // 删除
    await tester.tap(find.byTooltip('删除').first);
    await tester.pump();
    expect(_rules(tester, CustomRulesPage).map((r) => r.value), ['example.org', '1.2.3.4']);
  });
}
