import 'dart:async';

import 'package:bett_box/meowx/app/meow_tab.dart';
import 'package:bett_box/meowx/config/direct_profile.dart';
import 'package:bett_box/meowx/pages/dashboard/info_cards.dart';
import 'package:bett_box/meowx/panel/account.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 首页订阅卡（同 iOS）：直连档的样子、点更新时间刷新、切换菜单里的「账户订阅 · 未下载」与去重。
// 账户动作换成记账的替身，不碰 globalState / 网络。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
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

class _Actions extends AccountActions {
  _Actions(super.ref);

  final refreshed = <String>[];
  final imported = <String>[];
  int fetches = 0;
  Completer<void>? refreshGate;

  @override
  Future<void> refreshLocalSubscription(Profile profile) async {
    refreshed.add(profile.id);
    await refreshGate?.future;
  }

  @override
  Future<void> importSubscription(RemoteSubscription sub) async => imported.add(sub.name);

  @override
  Future<void> refreshSubscriptionsIfNeeded() async => fetches++;
}

const _host = 'https://panel.example.com';

final _direct = Profile(id: directProfileId, label: directProfileLabel, url: '', autoUpdateDuration: const Duration(days: 1));

final _main = Profile(
  id: 'p1',
  label: '妙妙屋 · 主力订阅（名字特别长的那种套餐，挤一挤右边的按钮）',
  url: 'https://sub.example.net/x/aaa?t=meowx',
  lastUpdateDate: DateTime.now().subtract(const Duration(hours: 3)),
  autoUpdateDuration: const Duration(days: 1),
  subscriptionInfo: const SubscriptionInfo(upload: 1073741824 * 8, download: 129278519706, total: 1073741824 * 500, expire: 1798718400),
);

const _remote = [
  RemoteSubscription(name: '主力', filename: 'a.yaml', subscriptionPath: '/x/aaa'),
  RemoteSubscription(name: '备用套餐', filename: 'b.yaml', subscriptionPath: 'x/bbb'),
];

Future<_Actions> _pump(
  WidgetTester tester, {
  required Profile current,
  bool dense = false,
  bool loggedIn = false,
  AsyncValue<List<RemoteSubscription>> remote = const AsyncValue.data([]),
  Size size = const Size(320, 700),
  double textScale = 1.4,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final card = HomeSubscriptionCard(dense: dense);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meowSettingProvider.overrideWith(
          () => _Meow(MeowSettings(account: MeowAccount(host: _host, token: loggedIn ? 'tok' : ''))),
        ),
        profilesProvider.overrideWith(() => _Profiles([_main, _direct])),
        currentProfileIdProvider.overrideWith(() => _ProfileId(current.id)),
        currentProfileProvider.overrideWith((ref) => ref.watch(profilesProvider).getProfile(ref.watch(currentProfileIdProvider))),
        remoteSubsProvider.overrideWith((ref) => remote),
        accountActionsProvider.overrideWith(_Actions.new),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            // 宽屏首页把卡片放在 IntrinsicHeight 里：紧凑版同样摆一次，确认不依赖 LayoutBuilder
            child: Align(alignment: Alignment.topCenter, child: dense ? IntrinsicHeight(child: card) : card),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // provider 是懒建的：没登录时卡片一次都不读它，这里读出来（同一个实例）给用例记账
  return ProviderScope.containerOf(tester.element(find.byType(HomeSubscriptionCard))).read(accountActionsProvider) as _Actions;
}

Future<void> _openMenu(WidgetTester tester, String chip) async {
  await tester.tap(find.text(chip));
  await tester.pumpAndSettle();
}

void main() {
  for (final dense in [false, true]) {
    final tag = dense ? '紧凑版' : '手机';

    testWidgets('$tag · 内置直连档：实心「选择订阅」+ 直连提示，没有用量条和用量行', (tester) async {
      await _pump(tester, current: _direct, dense: dense, size: dense ? const Size(520, 400) : const Size(320, 400));

      expect(find.text(directProfileLabel), findsOneWidget);
      expect(find.text('选择订阅'), findsOneWidget);
      expect(find.text('切换订阅'), findsNothing);
      expect(find.text('未使用订阅，流量全部直连'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byTooltip('刷新订阅'), findsNothing);
    });

    testWidgets('$tag · 在用订阅：用量条 + 用量 · 到期；点更新时间刷新当前订阅，刷新中换成转圈', (tester) async {
      final actions = await _pump(tester, current: _main, dense: dense, size: dense ? const Size(520, 400) : const Size(320, 400));

      expect(find.text('切换订阅'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('128.4 / 500 GB · 到期 2026-12-31'), findsOneWidget);
      expect(find.text('3 小时前更新'), findsOneWidget);

      actions.refreshGate = Completer<void>();
      await tester.tap(find.text('3 小时前更新'));
      await tester.pump();
      expect(actions.refreshed, ['p1']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // 刷新中再点不重复发
      await tester.tap(find.text('3 小时前更新'));
      await tester.pump();
      expect(actions.refreshed, ['p1']);

      actions.refreshGate!.complete();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('$tag · 切换菜单：本机订阅 +「账户订阅 · 未下载」（已下载的不重复）+ 导入；点未下载的先下载', (tester) async {
      final actions = await _pump(
        tester,
        current: _main,
        dense: dense,
        loggedIn: true,
        remote: const AsyncValue.data(_remote),
        size: dense ? const Size(520, 800) : const Size(360, 800),
      );
      // 首页出现时问一次要不要拉账户订阅（节流在 AccountActions 里）
      expect(actions.fetches, 1);

      await _openMenu(tester, '切换订阅');
      expect(find.text(directProfileLabel), findsOneWidget);
      expect(find.text('账户订阅 · 未下载'), findsOneWidget);
      // 「主力」的短链路径与本机那份（挂在订阅域名上）相同：已下载，不再列
      expect(find.text('↓ 主力'), findsNothing);
      expect(find.text('↓ 备用套餐'), findsOneWidget);
      expect(find.text('导入订阅…'), findsOneWidget);

      await tester.tap(find.text('↓ 备用套餐'));
      await tester.pumpAndSettle();
      expect(actions.imported, ['备用套餐']);
    });
  }

  testWidgets('账户订阅还在拉：菜单那一节显示「加载中…」；没登录不出现这一节', (tester) async {
    await _pump(tester, current: _main, loggedIn: true, remote: const AsyncValue.loading(), size: const Size(360, 800));
    await _openMenu(tester, '切换订阅');
    expect(find.text('账户订阅 · 未下载'), findsOneWidget);
    expect(find.text('加载中…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    final actions = await _pump(tester, current: _main, remote: const AsyncValue.data(_remote), size: const Size(360, 800));
    expect(actions.fetches, 0);
    await _openMenu(tester, '切换订阅');
    expect(find.text('账户订阅 · 未下载'), findsNothing);
    expect(find.text('↓ 备用套餐'), findsNothing);
  });

  testWidgets('点订阅名同样打开菜单；选本机另一份 = 切过去，「导入订阅…」去「我的」', (tester) async {
    await _pump(tester, current: _main, size: const Size(360, 800));
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeSubscriptionCard)));

    await tester.tap(find.text(_main.label!));
    await tester.pumpAndSettle();
    await tester.tap(find.text(directProfileLabel));
    await tester.pumpAndSettle();
    expect(container.read(currentProfileIdProvider), directProfileId);
    expect(find.text('选择订阅'), findsOneWidget);

    await _openMenu(tester, '选择订阅');
    await tester.tap(find.text('导入订阅…'));
    await tester.pumpAndSettle();
    expect(container.read(meowTabProvider), MeowTab.me);
  });
}
