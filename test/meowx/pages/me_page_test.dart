import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/pages/me/me_page.dart';
import 'package:bett_box/meowx/pages/me/platform_rows.dart';
import 'package:bett_box/meowx/pages/me/settings_rows.dart';
import 'package:bett_box/meowx/pages/settings/overrides_pages.dart';
import 'package:bett_box/meowx/pages/settings/sys_proxy_bypass_page.dart';
import 'package:bett_box/meowx/panel/account.dart';
import 'package:bett_box/meowx/state/connection.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
  // 与本机的 p1 同名同主控 → 已导入，不再重复列
  RemoteSubscription(name: '妙妙屋 · 主力订阅（名字特别长的那种套餐，用来挤一挤右边的徽标和菜单）', filename: 'a.yaml', subscriptionPath: '/a'),
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
          ),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
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
    for (final label in ['代理与测速', '流量控制', '本地代理', '订阅同步', '日志', '外观', '高级', '关于']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('跟随订阅 · HTTPS 延迟'), findsOneWidget);
    expect(find.text('0.2.0 · 检查更新'), findsOneWidget);
  });

  testWidgets('手机 · 已登录：当前档展开显示用量，已导入的账户订阅不重复列，没导入的带下载入口', (tester) async {
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
    expect(find.text('实时同步已启用 · panel.example.com'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('128.0 / 500 GB'), findsOneWidget);
    expect(find.textContaining('到期 2026-12-31'), findsOneWidget);
    expect(find.text('12.0 / 100 GB'), findsOneWidget);
    expect(find.text('内置'), findsOneWidget);
    expect(find.text(_main.label!), findsOneWidget);   // 只有本机那一档，账户订阅里的同名项没再列
    expect(find.text('还没导入的订阅'), findsOneWidget);
    expect(find.text('每天 · po0 加白'), findsOneWidget);

    // 点别的档 = 设为当前
    await tester.tap(find.text('备用订阅'));
    await tester.pump();
    expect(_container(tester, MePage).read(currentProfileIdProvider), 'p2');
  });

  testWidgets('手机 · 入口行进二级页，返回钮回来；二级页里的开关直接生效', (tester) async {
    await _pump(tester, const MePage(), size: const Size(412, 1500), overrides: _overrides(), textScale: 1);
    await tester.tap(find.text('流量控制'));
    await tester.pumpAndSettle();
    expect(find.text('阻止 QUIC'), findsOneWidget);
    expect(find.text('代理推送服务'), findsOneWidget);
    expect(find.text('DNS 劫持'), findsOneWidget);
    expect(find.text('绕过代理'), findsOneWidget);

    await tester.tap(find.text('阻止 QUIC'));
    await tester.pump();
    expect(_container(tester, MeSubPage).read(vpnSettingProvider).disableQuic, isTrue);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('代理推送服务'), findsNothing);
    expect(find.text('阻止 QUIC'), findsOneWidget);   // 回到「我的」：入口行的摘要跟着变
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
          MeSection(children: [LogRows()]),
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
}
