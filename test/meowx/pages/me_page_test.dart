import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/pages/me/me_page.dart';
import 'package:bett_box/meowx/pages/me/me_sheet.dart';
import 'package:bett_box/meowx/pages/me/platform_rows.dart';
import 'package:bett_box/meowx/pages/me/settings_rows.dart';
import 'package:bett_box/meowx/pages/settings/overrides_pages.dart';
import 'package:bett_box/meowx/pages/settings/ggy_tokens_page.dart';
import 'package:bett_box/meowx/pages/settings/po0_servers_page.dart';
import 'package:bett_box/meowx/panel/ggy.dart';
import 'package:bett_box/meowx/panel/po0.dart';
import 'package:bett_box/meowx/pages/settings/sys_proxy_bypass_page.dart';
import 'package:bett_box/meowx/panel/account.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/ggy_reporter.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/motion.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../support/haptics.dart';

// 各 Notifier 换成不碰 globalState 落盘 / 核心 / 网络的替身，页面本身的布局与交互保持真实。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _App extends AppSetting {
  @override
  AppSettingProps build() => const AppSettingProps(autoRun: true);

  @override
  void onUpdate(AppSettingProps value) {}
}

class _Vpn extends VpnSetting {
  @override
  VpnProps build() => const VpnProps(networkSpeedNotification: true);

  @override
  void onUpdate(VpnProps value) {}
}

class _Network extends NetworkSetting {
  @override
  NetworkProps build() => const NetworkProps();

  @override
  void onUpdate(NetworkProps value) {}
}

class _Theme extends ThemeSetting {
  @override
  ThemeProps build() => const ThemeProps();

  @override
  void onUpdate(ThemeProps value) {}
}

class _Patch extends PatchClashConfig {
  @override
  ClashConfig build() => const ClashConfig();

  @override
  void onUpdate(ClashConfig value) {}
}

class _HotKeys extends HotKeyActions {
  @override
  List<HotKeyAction> build() => const [
    HotKeyAction(action: HotAction.start, key: 0x00070016, modifiers: {KeyboardModifier.control, KeyboardModifier.alt}),
  ];

  @override
  void onUpdate(List<HotKeyAction> value) {}
}

class _LocalIp extends LocalIp {
  @override
  String? build() => '192.168.31.120';

  @override
  void onUpdate(String? value) {}
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

const _gb = 1024 * 1024 * 1024;

final _main = Profile(
  id: 'p1',
  label: '妙妙屋 · 主力订阅（名字特别长的那种套餐，用来挤一挤右边的徽标和菜单）',
  url: 'https://panel.example.com/sub/a',
  lastUpdateDate: DateTime.now().subtract(const Duration(hours: 3)),
  autoUpdateDuration: const Duration(days: 1),
  subscriptionInfo: const SubscriptionInfo(upload: _gb * 2, download: _gb * 126, total: _gb * 500, expire: 1798718400),
);

final _backup = Profile(
  id: 'p2',
  label: '备用订阅',
  url: 'https://other.example.com/sub/b',
  lastUpdateDate: DateTime.now(),
  autoUpdateDuration: const Duration(days: 1),
  subscriptionInfo: const SubscriptionInfo(upload: 0, download: _gb * 12, total: _gb * 100, expire: 1798718400),
);

final _direct = Profile(
  id: '00000000-0000-0000-0000-0000D1EC7000',
  label: '直连（不走代理）',
  lastUpdateDate: DateTime.now(),
  autoUpdateDuration: const Duration(days: 1),
);

const _account = MeowAccount(host: 'https://panel.example.com', token: 't', nickname: '一个昵称特别特别特别长的用户');

const _remote = [
  // 短链路径与本机的 p1 相同 → 已下载，不再重复列（名字不同也一样：按地址认，不看档名）
  RemoteSubscription(name: '主力订阅（主控上的名字）', filename: 'a.yaml', subscriptionPath: '/sub/a'),
  RemoteSubscription(name: '还没导入的订阅', filename: 'c.yaml', subscriptionPath: '/c', trafficUsed: _gb, trafficTotal: _gb * 50),
];

List<Override> _overrides({
  bool wide = false,
  bool twoPane = false,
  MeowSettings meow = const MeowSettings(),
  List<Profile> profiles = const [],
  String? current,
  List<RemoteSubscription> remote = const [],
}) => [
  isRunningProvider.overrideWithValue(false),
  isWideLayoutProvider.overrideWithValue(wide),
  isTwoPaneProvider.overrideWithValue(twoPane),
  declaredDnsModeProvider.overrideWithValue('fake-ip'),
  tunEnabledProvider.overrideWithValue(true),
  systemProxyEnabledProvider.overrideWithValue(false),
  tunHintProvider.overrideWithValue(('未安装 MeowX 服务 · 开启时安装', true)),
  meowSettingProvider.overrideWith(() => _Meow(meow)),
  appSettingProvider.overrideWith(_App.new),
  vpnSettingProvider.overrideWith(_Vpn.new),
  networkSettingProvider.overrideWith(_Network.new),
  themeSettingProvider.overrideWith(_Theme.new),
  patchClashConfigProvider.overrideWith(_Patch.new),
  hotKeyActionsProvider.overrideWith(_HotKeys.new),
  localIpProvider.overrideWith(_LocalIp.new),
  profilesProvider.overrideWith(() => _Profiles(profiles)),
  currentProfileIdProvider.overrideWith(() => _ProfileId(current)),
  remoteSubsProvider.overrideWith((ref) => AsyncValue.data(remote)),
];

/// 按给定窗口尺寸与文字缩放摆出来（溢出会作为异常让用例失败）。
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required Size size,
  required List<Override> overrides,
  double textScale = 1.4,
  double bottomInset = 0,
  bool disableAnimations = false,
}) async {
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
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: EdgeInsets.only(bottom: bottomInset),
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

const _phone = Size(412, 892);

/// 卡片的内容区（页头 + 正文，不含抓手）：它的高度就是卡片随内容变化的那部分。
Finder _sheetBody() => find.ancestor(of: find.byType(MeSheetScope).first, matching: find.byType(AnimatedSize));

/// 卡片内容区的最高高度：屏幕 88% 减去抓手那一条（测试里没有顶部安全区）。
double _maxBody(Size screen) => screen.height * MeowMotion.sheetMaxHeight - 15;

/// 滚到入口行、点开它的设置卡片，等卡片完全升起。
Future<void> _openSheet(WidgetTester tester, String entry) async {
  final row = find.widgetWithText(MeRow, entry).first;
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
  expect(find.byType(MeSheetScope), findsOneWidget);
}

ProviderContainer _container(WidgetTester tester, Type type) => ProviderScope.containerOf(tester.element(find.byType(type).first));

void main() {
  setUpAll(() {
    globalState.packageInfo = PackageInfo(appName: 'MeowX', packageName: 'com.miaomiaowux.app', version: '0.2.0', buildNumber: '1');
  });

  testWidgets('手机 · 未登录、没有订阅：窄屏 1.4 倍字号不溢出；账户 / 订阅 / 全部设置入口都在', (tester) async {
    await _pump(tester, const MePage(), size: const Size(320, 1700), overrides: _overrides(), bottomInset: 96);
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('账号登录'), findsOneWidget);
    expect(find.text('导入订阅'), findsOneWidget);
    expect(find.textContaining('还没有订阅'), findsOneWidget);
    for (final label in ['代理与测速', '流量控制', '本地代理', '订阅同步', '记录日志', '外观', '高级', '关于']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('跟随订阅 · HTTPS 延迟'), findsOneWidget);
    expect(find.text('0.2.0 · 检查更新'), findsOneWidget);
    // 入口行末尾的箭头垫 40×30 奶白胶囊；开关行没有
    final chevron = find.descendant(of: find.widgetWithText(MeRow, '流量控制'), matching: find.byType(MeowChip));
    expect(tester.getSize(chevron), const Size(MeowChip.width, MeowChip.height));
    expect(find.descendant(of: find.byType(LogSwitchRow), matching: find.byType(MeowChip)), findsNothing);
  });

  testWidgets('手机 · 已登录：当前档展开显示用量；账户下的订阅单独一组、全部列出（同 iOS）', (tester) async {
    await _pump(
      tester,
      const MePage(),
      size: const Size(320, 1900),
      overrides: _overrides(
        meow: const MeowSettings(account: _account, po0Enabled: true),
        profiles: [_main, _backup, _direct],
        current: 'p1',
        remote: _remote,
      ),
      bottomInset: 96,
    );
    expect(find.text('一个昵称特别特别特别长的用户'), findsOneWidget);
    expect(find.text('实时同步已启用'), findsOneWidget);   // 不带主控域名（同 iOS）
    expect(find.text('退出'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('128.0 / 500 GB'), findsOneWidget);
    expect(find.textContaining('到期 2026-12-31'), findsOneWidget);
    expect(find.text('12.0 / 100 GB'), findsOneWidget);
    expect(find.text('内置'), findsOneWidget);
    expect(find.text(_main.label!), findsOneWidget);
    expect(find.text('账户下的订阅'), findsOneWidget);
    expect(find.text('主力订阅（主控上的名字）'), findsOneWidget);   // 已下载的也列（点了直接切过去）
    expect(find.text('还没导入的订阅'), findsOneWidget);
    expect(find.text('每天 · po0 加白'), findsOneWidget);

    // 点别的档 = 设为当前
    await tester.tap(find.text('备用订阅'));
    await tester.pump();
    expect(_container(tester, MePage).read(currentProfileIdProvider), 'p2');
  });

  testWidgets('账户订阅认「已下载」按地址：开了订阅域名（主机名不同、短链路径相同）也认得出，点了直接切到那一档', (tester) async {
    final viaSubDomain = _main.copyWith(id: 'p3', label: '本机改过名的那份', url: 'https://sub.example.net/x/aaa?t=meowx');
    final sameName = _main.copyWith(id: 'p4', label: '同名套餐', url: 'https://panel.example.com/x/old');
    await _pump(
      tester,
      const MePage(),
      size: const Size(412, 1900),
      overrides: _overrides(
        meow: const MeowSettings(account: _account),
        profiles: [viaSubDomain, sameName, _direct],
        current: 'p4',
        remote: const [
          RemoteSubscription(name: '主力（订阅域名）', filename: 'a.yaml', subscriptionPath: 'x/aaa'),
          RemoteSubscription(name: '同名套餐', filename: 'n.yaml', subscriptionPath: '/x/new'),
        ],
      ),
      textScale: 1,
    );
    expect(find.text('主力（订阅域名）'), findsOneWidget);
    expect(find.text('同名套餐'), findsNWidgets(2));   // 本机一份 + 账户下一份（地址不同，是两份）
    // 主机名不同、短链路径相同：认出是本机的 p3，点了切过去（不重复下载）
    await tester.tap(find.text('主力（订阅域名）'));
    await tester.pump();
    expect(_container(tester, MePage).read(currentProfileIdProvider), 'p3');
  });

  testWidgets('订阅菜单「重命名」：只改本机档名（留空不动、不切档）；内置直连档没有这一项', (tester) async {
    await _pump(
      tester,
      const MePage(),
      size: const Size(412, 1900),
      overrides: _overrides(profiles: [_main, _backup, _direct], current: 'p1'),
      textScale: 1,
    );
    final container = _container(tester, MePage);
    String? label(String id) => container.read(profilesProvider).getProfile(id)?.label;
    final input = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    // 点了菜单项先亮选中块，menuAutoClose 之后才关菜单、回传
    Future<void> pick(String item) async {
      await tester.tap(find.text(item));
      await tester.pump(MeowMotion.menuAutoClose);
      await tester.pumpAndSettle();
    }
    Future<void> submit(String text) async {
      await tester.enterText(input, text);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
    }

    // 当前档：「⋯」→「重命名」，输入框带着原名；前后空格去掉
    await tester.tap(find.byTooltip('订阅管理'));
    await tester.pumpAndSettle();
    await pick('重命名');
    expect(tester.widget<TextField>(input).controller!.text, _main.label);
    await submit('  家里那份  ');
    expect(label('p1'), '家里那份');
    expect(find.text('家里那份'), findsOneWidget);

    // 留空 = 不改
    await tester.tap(find.byTooltip('订阅管理'));
    await tester.pumpAndSettle();
    await pick('重命名');
    await submit('   ');
    expect(label('p1'), '家里那份');

    // 其它档长按弹同一份菜单；改名不切档
    await tester.longPress(find.text('备用订阅'));
    await tester.pumpAndSettle();
    await pick('重命名');
    await submit('备用 · 公司');
    expect(label('p2'), '备用 · 公司');
    expect(container.read(currentProfileIdProvider), 'p1');

    // 内置直连档：菜单里没有「重命名」
    await tester.longPress(find.text(_direct.label!));
    await tester.pumpAndSettle();
    expect(find.text('查看配置'), findsOneWidget);
    expect(find.text('重命名'), findsNothing);
  });

  testWidgets('订阅菜单「刷新」：轻震一下；只打开菜单、选别的项不震', (tester) async {
    final haptics = recordHaptics();
    await _pump(
      tester,
      const MePage(),
      size: const Size(412, 1900),
      overrides: _overrides(profiles: [_main, _backup, _direct], current: 'p1'),
      textScale: 1,
    );
    Future<void> pick(String item) async {
      await tester.tap(find.byTooltip('订阅管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pump(MeowMotion.menuAutoClose);
      await tester.pumpAndSettle();
    }

    await pick('重命名');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(haptics, isEmpty);
    // 刷新本身经 appController 拉订阅（测试里没有，报错显示在页面上），这里只看震动
    await pick('刷新');
    expect(haptics, [kLight]);
  });

  testWidgets('账户卡头像：主控上传的站内路径接上主控地址再去加载', (tester) async {
    await _pump(
      tester,
      const MePage(),
      size: const Size(412, 1500),
      overrides: _overrides(meow: MeowSettings(account: _account.copyWith(avatarUrl: '/api/user/avatar/ab?v=2'))),
      textScale: 1,
    );
    final urls = tester
        .widgetList<Image>(find.byType(Image))
        .map((i) => i.image)
        .map((p) => p is ResizeImage ? p.imageProvider : p)
        .whereType<NetworkImage>()
        .map((n) => n.url)
        .toList();
    expect(urls, ['https://panel.example.com/api/user/avatar/ab?v=2']);
  });

  testWidgets('手机 · 入口行从底部升起设置卡片：高度贴合内容；卡片里的开关直接生效；点 × 关闭', (tester) async {
    await _pump(tester, const MePage(), size: _phone, overrides: _overrides(), textScale: 1);
    await _openSheet(tester, '流量控制');
    expect(find.text('阻止 QUIC'), findsOneWidget);
    expect(find.text('代理推送服务'), findsOneWidget);
    expect(find.text('DNS 劫持'), findsOneWidget);
    expect(find.text('绕过代理'), findsOneWidget);
    expect(find.text('流量控制'), findsNWidgets(2));   // 入口行 + 卡片页头
    expect(tester.getSize(_sheetBody()).height, lessThan(_maxBody(_phone) - 200));   // 只有四行：远不到最高

    await tester.tap(find.text('阻止 QUIC'));
    await tester.pump();
    expect(_container(tester, MeSubPage).read(vpnSettingProvider).disableQuic, isTrue);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(MeSheetScope), findsNothing);
    expect(find.text('代理推送服务'), findsNothing);
    expect(find.text('阻止 QUIC'), findsOneWidget);   // 回到「我的」：入口行的摘要跟着变
  });

  testWidgets('卡片里拨开关带出下一级（局域网地址）：卡片随内容平滑长高', (tester) async {
    await _pump(tester, const MePage(), size: const Size(320, 760), overrides: _overrides());
    await _openSheet(tester, '本地代理');
    final before = tester.getSize(_sheetBody()).height;
    expect(find.textContaining('192.168.31.120:7890'), findsNothing);

    await tester.tap(find.text('允许局域网'));
    await tester.pump();
    await tester.pump(MeowMotion.sheetResize ~/ 3);
    final mid = tester.getSize(_sheetBody()).height;
    await tester.pumpAndSettle();
    final after = tester.getSize(_sheetBody()).height;
    expect(find.textContaining('192.168.31.120:7890'), findsOneWidget);
    expect(after, greaterThan(before));
    expect(mid, inExclusiveRange(before, after));   // 不跳：中途停在两者之间
  });

  testWidgets('卡片里进下一层（DNS 劫持）：卡片拉到最高、页头换标题带返回；返回 / 系统返回键回到上一层并缩回原高度', (tester) async {
    const meow = MeowSettings(dnsHijack: {'hijack.example.com': '1.2.3.4'});
    await _pump(tester, const MePage(), size: _phone, overrides: _overrides(meow: meow), textScale: 1);
    await _openSheet(tester, '流量控制');
    final first = tester.getSize(_sheetBody()).height;

    await tester.tap(find.text('DNS 劫持'));
    await tester.pump();
    await tester.pump(MeowMotion.sheetPane ~/ 3);
    // 平推途中两层都在：新页从右边进来、旧页往左退
    expect(find.text('阻止 QUIC'), findsOneWidget);
    expect(find.text('hijack.example.com'), findsOneWidget);
    expect(tester.getTopLeft(find.text('hijack.example.com')).dx, greaterThan(tester.getTopLeft(find.text('阻止 QUIC')).dx));
    await tester.pumpAndSettle();
    expect(find.text('阻止 QUIC'), findsNothing);
    expect(find.byType(DnsHijackPage), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byTooltip('添加'), findsOneWidget);   // 下一层的操作钮放在卡片页头
    expect(tester.getSize(_sheetBody()).height, moreOrLessEquals(_maxBody(_phone)));
    expect(find.byType(Scaffold), findsOneWidget);   // 卡片里不再套一层整页骨架（只有测试外壳那一个）

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(DnsHijackPage), findsNothing);
    expect(find.text('阻止 QUIC'), findsOneWidget);
    expect(tester.getSize(_sheetBody()).height, moreOrLessEquals(first));

    // 系统返回键：先退一层，再关掉卡片
    await tester.tap(find.text('DNS 劫持'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DnsHijackPage), findsNothing);
    expect(find.byType(MeSheetScope), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MeSheetScope), findsNothing);
  });

  testWidgets('点遮罩关闭；下拉够远关闭、拉一点松手弹回；在下一层时点遮罩也直接关掉整张卡片', (tester) async {
    await _pump(tester, const MePage(), size: _phone, overrides: _overrides(), textScale: 1);
    await _openSheet(tester, '外观');
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.byType(MeSheetScope), findsNothing);

    await _openSheet(tester, '外观');
    final top = tester.getTopLeft(_sheetBody()).dy;
    await tester.drag(find.text('主题'), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(find.byType(MeSheetScope), findsOneWidget);
    expect(tester.getTopLeft(_sheetBody()).dy, moreOrLessEquals(top));
    await tester.drag(find.text('主题'), const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(find.byType(MeSheetScope), findsNothing);

    await _openSheet(tester, '流量控制');
    await tester.tap(find.text('绕过代理'));
    await tester.pumpAndSettle();
    expect(find.byType(BypassPage), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.byType(MeSheetScope), findsNothing);
  });

  testWidgets('卡片升起时背后整页缩小；「移除动画」时不缩放、卡片里换层不平移', (tester) async {
    await _pump(tester, const MeSheetBackdrop(child: MePage()), size: _phone, overrides: _overrides(), textScale: 1);
    Matrix4 backdrop() => tester.widget<Transform>(find.descendant(of: find.byType(MeSheetBackdrop), matching: find.byType(Transform)).first).transform;
    expect(backdrop().isIdentity(), isTrue);
    await _openSheet(tester, '流量控制');
    expect(backdrop().entry(0, 0), moreOrLessEquals(MeowMotion.sheetBackdropScale));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(backdrop().isIdentity(), isTrue);

    await _pump(tester, const MeSheetBackdrop(child: MePage()), size: _phone, overrides: _overrides(), textScale: 1, disableAnimations: true);
    await _openSheet(tester, '流量控制');
    expect(backdrop().isIdentity(), isTrue);
    await tester.tap(find.text('DNS 劫持'));
    await tester.pump();
    await tester.pump(MeowMotion.sheetFade ~/ 2);
    final shifts = tester.widgetList<FractionalTranslation>(
      find.descendant(of: find.byType(AnimatedSize), matching: find.byType(FractionalTranslation)),
    );
    expect(shifts, isNotEmpty);
    expect(shifts.every((f) => f.translation == Offset.zero), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(DnsHijackPage), findsOneWidget);
  });

  testWidgets('手机 · 「记录日志」直接是列表里的开关行：点了当场切换，不进二级页', (tester) async {
    await _pump(tester, const MePage(), size: const Size(412, 1500), overrides: _overrides(), textScale: 1);
    expect(find.text('开启后额外记录每条连接的分流与 DNS 详情'), findsOneWidget);
    final before = _container(tester, MePage).read(appSettingProvider).openLogs;
    await tester.tap(find.text('记录日志'));
    await tester.pumpAndSettle();
    expect(find.byType(MeSubPage), findsNothing);
    expect(_container(tester, MePage).read(appSettingProvider).openLogs, !before);
    expect(tester.widget<Switch>(find.descendant(of: find.byType(LogSwitchRow), matching: find.byType(Switch))).value, !before);
  });

  testWidgets('宽屏三列：最小窗口 1.4 倍字号不溢出；设置分组直接铺开，「高级设置」在标题行', (tester) async {
    for (final size in const [Size(900 - 100, 600), Size(1100 - 236, 680), Size(1700, 900)]) {
      await _pump(
        tester,
        const MePage(),
        size: size,
        overrides: _overrides(
          wide: true,
          twoPane: true,
          meow: const MeowSettings(account: _account),
          profiles: [_main, _backup, _direct],
          current: 'p1',
          remote: _remote,
        ),
      );
      for (final label in ['高级设置', '代理与测速', '流量控制', '本地代理 · 订阅', '外观 · 关于']) {
        expect(find.text(label), findsOneWidget, reason: '$label @ $size');
      }
      for (final label in ['DNS 模式', '测速方式', '测速地址', '阻止 QUIC', '代理推送服务', 'DNS 劫持', '绕过代理', '端口', '允许局域网', '用户名', '密码', '订阅同步间隔', 'po0 加白', '主题', '记录日志', '版本', '检查更新', '开源许可']) {
        expect(find.text(label), findsOneWidget, reason: '$label @ $size');
      }
    }
  });

  testWidgets('平台专属分组：窄列 1.4 倍字号不溢出；快捷键显示组合键 / 未设置', (tester) async {
    await _pump(
      tester,
      const SingleChildScrollView(
        child: MeDense(
          child: Column(
            children: [
              MeSection(title: '启动与窗口', note: '关闭按钮 = 收到托盘', accent: true, children: [StartupRows()]),
              MeSection(title: '接管方式', accent: true, children: [TakeoverRows()]),
              MeSection(title: '全局快捷键', accent: true, children: [HotkeyRows()]),
              MeSection(title: 'VPN 与系统', accent: true, children: [VpnSystemRows()]),
            ],
          ),
        ),
      ),
      size: const Size(230, 1400),
      overrides: _overrides(),
    );
    expect(find.text('未安装 MeowX 服务 · 开启时安装'), findsOneWidget);
    expect(find.text('CTRL + ALT + S'), findsOneWidget);
    expect(find.text('未设置'), findsNWidgets(HotAction.values.length - 1));

    await tester.tap(find.text('开机启动'));
    await tester.pump();
    expect(_container(tester, StartupRows).read(appSettingProvider).autoLaunch, isTrue);
    await tester.tap(find.text('网速通知'));
    await tester.pump();
    expect(_container(tester, StartupRows).read(vpnSettingProvider).networkSpeedNotification, isFalse);
  });

  testWidgets('通用分组的二级页排版（标准行）：窄屏 1.4 倍字号不溢出', (tester) async {
    await _pump(
      tester,
      MeSubPage.list(
        title: '全部设置项放一页',
        children: const [
          MeSection(children: [ProxyRows()]),
          MeSection(children: [TrafficRows(showProxyApps: true)]),
          MeSection(children: [LocalProxyRows()]),
          MeSection(children: [SyncRows()]),
          MeSection(children: [LogSwitchRow()]),
          MeSection(children: [AppearanceRows()]),
          MeSection(children: [AboutRows()]),
        ],
      ),
      size: const Size(320, 2400),
      overrides: _overrides(),
    );
    expect(find.textContaining('192.168.31.120:7890'), findsNothing);   // 没开局域网时只列本机地址
    expect(find.textContaining('127.0.0.1:7890'), findsOneWidget);
    expect(find.text('代理应用'), findsOneWidget);
  });

  testWidgets('绕过代理 / DNS 劫持 / 排除域名：列出条目，点 × 删除', (tester) async {
    const meow = MeowSettings(
      bypassDomains: ['a-very-long-subdomain.of.some.really-long-host-name.example.com', '+.example.org'],
      bypassCidrs: ['10.0.0.0/8'],
      dnsHijack: {'hijack.example.com': '1.2.3.4'},
    );
    await _pump(tester, const BypassPage(), size: const Size(320, 900), overrides: _overrides(meow: meow));
    expect(find.text('3 / 1000 · 命中的域名 / IP 直连，不经代理'), findsOneWidget);
    await tester.tap(find.byTooltip('删除').first);
    await tester.pump();
    final settings = _container(tester, BypassPage).read(meowSettingProvider);
    expect(settings.bypassDomains, ['+.example.org']);
    expect(settings.bypassCidrs, ['10.0.0.0/8']);

    await _pump(tester, const DnsHijackPage(), size: const Size(320, 900), overrides: _overrides(meow: meow));
    expect(find.text('hijack.example.com'), findsOneWidget);
    expect(find.text('1.2.3.4'), findsOneWidget);
    await tester.tap(find.byTooltip('删除'));
    await tester.pump();
    expect(_container(tester, DnsHijackPage).read(meowSettingProvider).dnsHijack, isEmpty);

    await _pump(tester, const SysProxyBypassPage(), size: const Size(320, 1600), overrides: _overrides());
    final before = _container(tester, SysProxyBypassPage).read(networkSettingProvider).bypassDomain;
    await tester.tap(find.byTooltip('删除').first);
    await tester.pump();
    expect(_container(tester, SysProxyBypassPage).read(networkSettingProvider).bypassDomain, before.sublist(1));
  });

  testWidgets('自定义 po0 服务器：入口行显示条数；列表只出现脱敏 token；添加时校验、去重；点 × 删除', (tester) async {
    const meow = MeowSettings(
      po0Enabled: true,
      po0Custom: [Po0CustomServer(address: 'fw.example.com:8443', token: 'pgnfw_abcd1234wxyz@2')],
    );
    await _pump(tester, const SingleChildScrollView(child: SyncRows()), size: const Size(320, 900), overrides: _overrides(meow: meow));
    expect(find.text('自定义 po0 服务器'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);
    await tester.tap(find.text('自定义 po0 服务器'));
    await tester.pumpAndSettle();

    expect(find.byType(Po0ServersPage), findsOneWidget);
    expect(find.text('fw.example.com:8443'), findsOneWidget);
    expect(find.text('pgnfw_••••wxyz@2'), findsOneWidget);
    expect(find.textContaining('abcd1234wxyz'), findsNothing);

    // 添加：地址 / token 不合法 → 各自的提示，不保存
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    final fields = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    expect(tester.widget<TextField>(fields.at(1)).obscureText, isTrue);
    await tester.enterText(fields.at(0), '1.2.3.4/api');
    await tester.enterText(fields.at(1), 'abc');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();
    expect(find.text(po0AddressPathMessage), findsOneWidget);
    expect(find.text(po0TokenInvalidMessage), findsOneWidget);

    // 与已有条目同一个上报地址 → 提示已添加
    await tester.enterText(fields.at(0), 'https://FW.example.com:08443/');
    await tester.enterText(fields.at(1), ' pgnfw_abcd1234wxyz@2 ');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();
    expect(find.text('这个地址与 token 已经添加过'), findsOneWidget);

    // 合法：存规范形式，列表里脱敏
    await tester.enterText(fields.at(0), '2001:DB8::1');
    await tester.enterText(fields.at(1), 'pgnfw_efgh5678ijkl');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(_container(tester, Po0ServersPage).read(meowSettingProvider).po0Custom.last,
        const Po0CustomServer(address: '[2001:db8::1]', token: 'pgnfw_efgh5678ijkl'));
    expect(find.text('[2001:db8::1]'), findsOneWidget);
    expect(find.text('pgnfw_••••ijkl'), findsOneWidget);
    expect(find.textContaining('efgh5678ijkl'), findsNothing);

    await tester.tap(find.byTooltip('删除').first);
    await tester.pump();
    expect(_container(tester, Po0ServersPage).read(meowSettingProvider).po0Custom.map((c) => c.address), ['[2001:db8::1]']);
  });

  testWidgets('GGY 加白：开关在 po0 后面、带说明；token 页只出现脱敏写法与上次结果；添加时解析整条链接、校验、去重；点 × 删除', (tester) async {
    // 只用假 token
    const a = 'ctecsfw_TESTtoken0000000000AAAA';
    const b = 'ctecsfw_TESTtoken0000000000BBBB';
    const meow = MeowSettings(ggyTokens: [a]);
    await _pump(
      tester,
      const SingleChildScrollView(child: SyncRows()),
      size: const Size(320, 1400),
      overrides: [
        ..._overrides(meow: meow),
        ggyResultsProvider.overrideWith(
          (ref) => {a: GgyResult(kind: GgyResultKind.tokenInvalid, reason: '白名单分享链接无效或已失效', at: DateTime(2026))},
        ),
      ],
    );
    expect(find.text(ggyDescription), findsOneWidget);
    // 说明整句显示：不像 po0 那行那样截到 3 行
    final desc = tester.renderObject<RenderParagraph>(find.text(ggyDescription));
    expect(desc.didExceedMaxLines, isFalse);
    expect(desc.size.height, greaterThan(tester.renderObject<RenderParagraph>(find.textContaining('上报到 po0')).size.height));
    expect(tester.getTopLeft(find.text('GGY 加白')).dy, greaterThan(tester.getTopLeft(find.text('自定义 po0 服务器')).dy));
    expect(find.text('1 个'), findsOneWidget);
    await tester.tap(find.text('GGY 加白'));
    await tester.pump();
    expect(_container(tester, SyncRows).read(meowSettingProvider).ggyEnabled, isTrue);

    await tester.tap(find.text('GGY token'));
    await tester.pumpAndSettle();
    expect(find.byType(GgyTokensPage), findsOneWidget);
    expect(find.text('ctecsfw_••••AAAA'), findsOneWidget);
    expect(find.text('token 无效或已失效'), findsOneWidget);
    expect(find.textContaining('重新生成分享链接'), findsOneWidget);
    expect(find.textContaining('TESTtoken'), findsNothing);

    // 添加：不合法 → 提示「token 格式不对」，不保存；输入框是密码样式
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.enterText(field, 'abc');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();
    expect(find.text(ggyTokenInvalidMessage), findsOneWidget);

    // 同一个 token 的整条链接 → 已添加过
    await tester.enterText(field, ' ${ggyReportUrl(a)} ');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();
    expect(find.text(ggyTokenDuplicateMessage), findsOneWidget);

    // 合法的整条链接：存取出来的 token，列表里脱敏、还没报过
    await tester.enterText(field, ggyReportUrl(b));
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(_container(tester, GgyTokensPage).read(meowSettingProvider).ggyTokens, [a, b]);
    expect(find.text('ctecsfw_••••BBBB'), findsOneWidget);
    expect(find.text('还没报过'), findsOneWidget);
    expect(find.textContaining('TESTtoken'), findsNothing);

    await tester.tap(find.byTooltip('删除').first);
    await tester.pump();
    expect(_container(tester, GgyTokensPage).read(meowSettingProvider).ggyTokens, [b]);
  });
}
