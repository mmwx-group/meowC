import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/connections/conn_rule_card.dart';
import 'package:bett_box/meowx/pages/me/settings_rows.dart';
import 'package:bett_box/meowx/pages/settings/custom_rules_page.dart';
import 'package:bett_box/meowx/state/custom_rules.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/overrides.dart';
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

class _Patch extends PatchClashConfig {
  _Patch(this.mode);
  final Mode mode;

  @override
  ClashConfig build() => ClashConfig(mode: mode);

  @override
  void onUpdate(ClashConfig value) {}
}

const _p = MeowRuleAction.proxy;
const _ruleModeCaption = '只在规则模式下生效，优先于订阅规则；之后的新连接起生效。';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  MeowSettings meow = const MeowSettings(),
  Size size = const Size(360, 900),
  double textScale = 1.4,
  Mode mode = Mode.rule,
  String? group = '节点选择',
}) async {
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
        patchClashConfigProvider.overrideWith(() => _Patch(mode)),
        mainProxyGroupProvider.overrideWithValue(group),
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

/// 动作按钮是不是高亮（选中态）
bool _selected(WidgetTester tester, String label) =>
    tester
        .widget<Semantics>(
          find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is Semantics && (w.properties.button ?? false))).first,
        )
        .properties
        .selected ??
    false;

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
    expect(find.text(_ruleModeCaption), findsOneWidget);

    // 默认含子域名
    await tester.tap(find.text('代理（节点选择）'));
    await tester.pumpAndSettle();
    expect(_rules(tester, ConnRuleCard), [const MeowCustomRule(value: 'www.youtube.com', match: MeowRuleMatch.suffix, action: _p)]);
    expect(find.text('当前规则：含子域名 www.youtube.com → 代理（节点选择）'), findsOneWidget);
    expect(_selected(tester, '代理（节点选择）'), isTrue);
    expect(_selected(tester, '直连'), isFalse);

    // 同一档再点别的动作：改动作，不新增
    await tester.tap(find.text('直连'));
    await tester.pumpAndSettle();
    expect(_rules(tester, ConnRuleCard), [const MeowCustomRule(value: 'www.youtube.com', match: MeowRuleMatch.suffix)]);
    expect(_selected(tester, '直连'), isTrue);

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

  testWidgets('连接详情：同一条规则被前面更宽的规则挡住时不高亮，点了挪到最前、立即生效', (tester) async {
    // 先「仅此域名 → 直连」、后来又加了「含子域名 → 拒绝」（放在最前）：生效的是拒绝
    await _pump(
      tester,
      const ConnRuleCard(host: 'www.youtube.com', ip: ''),
      meow: const MeowSettings(
        customRules: [
          MeowCustomRule(value: 'www.youtube.com', action: MeowRuleAction.reject),
          MeowCustomRule(value: 'www.youtube.com', match: MeowRuleMatch.domain),
        ],
      ),
    );
    // 停在生效的那一档（含子域名），高亮拒绝
    expect(find.text('当前规则：含子域名 www.youtube.com → 拒绝'), findsOneWidget);
    expect(_selected(tester, '拒绝'), isTrue);

    // 切到仅此域名：那条「直连」被挡住，不高亮
    await tester.tap(find.text('仅此域名'));
    await tester.pumpAndSettle();
    expect(_selected(tester, '直连'), isFalse);
    expect(_selected(tester, '拒绝'), isFalse);

    // 点直连：挪到最前，当前规则换成它
    await tester.tap(find.text('直连'));
    await tester.pumpAndSettle();
    expect(_rules(tester, ConnRuleCard), const [
      MeowCustomRule(value: 'www.youtube.com', match: MeowRuleMatch.domain),
      MeowCustomRule(value: 'www.youtube.com', action: MeowRuleAction.reject),
    ]);
    expect(find.text('当前规则：仅此域名 www.youtube.com → 直连'), findsOneWidget);
    expect(_selected(tester, '直连'), isTrue);
  });

  testWidgets('连接详情：父域名的规则也算「当前规则」（不高亮本域名的按钮）；只有 IP 的连接按 IP 加（没有匹配方式可选）', (tester) async {
    await _pump(
      tester,
      const ConnRuleCard(host: 'mail.google.com', ip: ''),
      meow: const MeowSettings(customRules: [MeowCustomRule(value: 'google.com', action: _p)]),
    );
    expect(find.text('当前规则：含子域名 google.com → 代理（节点选择）'), findsOneWidget);
    expect(_selected(tester, '代理（节点选择）'), isFalse);

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

  testWidgets('连接详情：域名连接不拿详情里的目标 IP 去比 IP 规则（内核里 IP 规则是 no-resolve，匹配时还没有这个 IP）', (tester) async {
    await _pump(
      tester,
      const ConnRuleCard(host: 'www.example.com', ip: '1.2.3.4'),
      meow: const MeowSettings(customRules: [MeowCustomRule(value: '1.2.3.4', match: MeowRuleMatch.ip, action: MeowRuleAction.reject)]),
    );
    expect(find.text('这个域名走'), findsOneWidget);
    expect(find.textContaining('当前规则'), findsNothing);
    // 域名带下划线也按域名加（同 iOS），不退回 IP 规则
    await _pump(tester, const ConnRuleCard(host: 'foo_bar.example.com', ip: '1.2.3.4'));
    expect(find.text('这个域名走'), findsOneWidget);
    expect(find.text('foo_bar.example.com'), findsOneWidget);
  });

  testWidgets('连接详情：不在规则模式时提示自定义规则不生效；没有代理组时「代理」不带组名', (tester) async {
    await _pump(tester, const ConnRuleCard(host: 'www.example.com', ip: ''), mode: Mode.global, group: null);
    expect(find.text('当前是全局模式，自定义规则不生效（只在规则模式下生效）。'), findsOneWidget);
    expect(find.text(_ruleModeCaption), findsNothing);
    expect(find.text('代理'), findsOneWidget);
  });

  testWidgets('连接详情：满 1000 条时新加提示「最多 1000 条」、不加；已有的照样能改', (tester) async {
    final full = [for (var i = 0; i < overridesLimit; i++) MeowCustomRule(value: 'h$i.example.com')];
    await _pump(tester, const ConnRuleCard(host: 'new.example.com', ip: ''), meow: MeowSettings(customRules: full));
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(find.text(overridesLimitMessage), findsOneWidget);
    expect(_rules(tester, ConnRuleCard), full);

    await _pump(tester, const ConnRuleCard(host: 'h5.example.com', ip: ''), meow: MeowSettings(customRules: full));
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(find.text(overridesLimitMessage), findsNothing);
    final after = _rules(tester, ConnRuleCard);
    expect(after, hasLength(overridesLimit));
    expect(after.first, const MeowCustomRule(value: 'h5.example.com', action: MeowRuleAction.reject));
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

  testWidgets('设置：订阅里没有代理组时「代理」不带组名，编辑框提示代理规则不生效', (tester) async {
    await _pump(
      tester,
      const CustomRulesPage(),
      meow: const MeowSettings(customRules: [MeowCustomRule(value: 'example.org', action: _p)]),
      group: null,
    );
    expect(find.text('含子域名 · 代理'), findsOneWidget);
    await tester.tap(find.text('example.org'));
    await tester.pumpAndSettle();
    expect(find.text('订阅里没有代理组：「代理」规则不生效，按订阅规则走'), findsOneWidget);
  });
}
