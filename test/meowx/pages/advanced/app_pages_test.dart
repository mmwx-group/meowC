import 'package:bett_box/common/common.dart';
import 'package:bett_box/meowx/pages/advanced/app/app_settings_page.dart';
import 'package:bett_box/meowx/pages/advanced/app/backup_page.dart';
import 'package:bett_box/meowx/pages/advanced/app/developer_page.dart';
import 'package:bett_box/meowx/pages/advanced/app/language_row.dart';
import 'package:bett_box/meowx/pages/advanced/app/loopback_row.dart';
import 'package:bett_box/meowx/pages/advanced/app/other_settings_page.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/haptics.dart';

// 各 Notifier 换成不落盘的替身，页面本身的布局与交互保持真实。

class _App extends AppSetting {
  _App(this.initial);
  final AppSettingProps initial;

  @override
  AppSettingProps build() => initial;

  @override
  void onUpdate(AppSettingProps value) {}
}

class _Vpn extends VpnSetting {
  _Vpn(this.initial);
  final VpnProps initial;

  @override
  VpnProps build() => initial;

  @override
  void onUpdate(VpnProps value) {}
}

class _Dav extends AppDAVSetting {
  _Dav(this.initial);
  final DAV? initial;

  @override
  DAV? build() => initial;

  @override
  void onUpdate(DAV? value) {}
}

class _Patch extends PatchClashConfig {
  @override
  ClashConfig build() => const ClashConfig();

  @override
  void onUpdate(ClashConfig value) {}
}

List<Override> _overrides({
  AppSettingProps app = const AppSettingProps(),
  VpnProps vpn = const VpnProps(),
  DAV? dav,
}) => [
  appSettingProvider.overrideWith(() => _App(app)),
  vpnSettingProvider.overrideWith(() => _Vpn(vpn)),
  appDAVSettingProvider.overrideWith(() => _Dav(dav)),
  patchClashConfigProvider.overrideWith(_Patch.new),
];

/// 360 宽、1.4 倍字号摆出来（溢出会作为异常让用例失败）。
Future<void> _pump(WidgetTester tester, Widget child, List<Override> overrides, {double height = 1400}) async {
  final size = Size(360, height);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox.shrink());
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
      overrides: overrides,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pump();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MeSubPage).first));

Future<void> _tapRow(WidgetTester tester, String label) async {
  final row = find.widgetWithText(MeRow, label).first;
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  setUp(recordHaptics);

  testWidgets('应用设置：窄屏不溢出；开关写回 appSettingProvider', (tester) async {
    await _pump(tester, const AppSettingsPage(), _overrides());
    for (final label in ['联动开关', '自动关闭连接', '代理流量统计', '自动检查更新']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // 测试机是 macOS：「我的」页没有启动与窗口那一组，所以这里列出开机启动 / 静默启动 / 自动连接
    if (system.isMacOS) {
      for (final label in ['开机启动', '静默启动', '自动连接']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    }
    expect(find.text('后台隐藏'), findsNothing);   // 只 Android

    final before = _container(tester).read(appSettingProvider);
    await _tapRow(tester, '自动关闭连接');
    expect(_container(tester).read(appSettingProvider).closeConnections, !before.closeConnections);
    await _tapRow(tester, '自动检查更新');
    expect(_container(tester).read(appSettingProvider).autoCheckUpdate, !before.autoCheckUpdate);
  });

  testWidgets('其它设置：智能启停打开后出现网络匹配，校验与写回照原样；商店修复改 hosts', (tester) async {
    await _pump(tester, const OtherSettingsPage(), _overrides());
    expect(find.text('网络匹配'), findsNothing);
    expect(find.text('排除国内'), findsNothing);   // 禁用 QUIC 关着

    await _tapRow(tester, '智能启停');
    final container = _container(tester);
    expect(container.read(vpnSettingProvider).smartAutoStop, isTrue);
    expect(find.text('网络匹配'), findsOneWidget);

    await _tapRow(tester, '网络匹配');
    await tester.enterText(find.byType(TextFormField), 'not an ip');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('无效的 IP 或 CIDR 格式'), findsOneWidget);   // 校验不过不关对话框
    await tester.enterText(find.byType(TextFormField), '192.168.1.0/24');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(container.read(vpnSettingProvider).smartAutoStopNetworks, '192.168.1.0/24');

    // 页面不 watch 覆写配置：测试里先挂一个监听，免得 autoDispose 把写进去的值丢掉
    container.listen(patchClashConfigProvider, (_, _) {});
    await _tapRow(tester, '商店修复');
    expect(container.read(vpnSettingProvider).storeFix, isTrue);
    expect(container.read(patchClashConfigProvider).hosts['services.googleapis.cn'], 'services.googleapis.com');
    await _tapRow(tester, '商店修复');
    expect(container.read(patchClashConfigProvider).hosts.containsKey('services.googleapis.cn'), isFalse);
  });

  testWidgets('其它设置：禁用 QUIC 开着时出现「排除国内」，俄语界面不出现', (tester) async {
    await _pump(tester, const OtherSettingsPage(), _overrides(vpn: const VpnProps(disableQuic: true)));
    expect(find.text('排除国内'), findsOneWidget);
    await _pump(
      tester,
      const OtherSettingsPage(),
      _overrides(vpn: const VpnProps(disableQuic: true), app: const AppSettingProps(locale: 'ru')),
    );
    expect(find.text('排除国内'), findsNothing);
  });

  testWidgets('备份与恢复：没绑定时只有「绑定」；绑定写入 WebDAV 设置', (tester) async {
    await _pump(tester, const BackupPage(), _overrides());
    expect(find.text('请绑定 WebDAV'), findsOneWidget);
    expect(find.text('文件'), findsNothing);
    expect(find.text('恢复策略'), findsOneWidget);
    expect(find.text('兼容'), findsOneWidget);

    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的 WebDAV 地址'), findsOneWidget);   // 校验不过不保存
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'https://dav.example.com/dav');
    await tester.enterText(fields.at(1), 'meow');
    await tester.enterText(fields.at(2), 'secret');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final dav = _container(tester).read(appDAVSettingProvider);
    expect(dav, const DAV(uri: 'https://dav.example.com/dav', user: 'meow', password: 'secret'));
    // 绑定后进入已绑定的版式（客户端开始测连通性）；换掉页面，别把在飞的测试留给下一个用例
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('备份与恢复：已绑定时改文件名、恢复默认', (tester) async {
    await _pump(
      tester,
      const BackupPage(),
      _overrides(dav: const DAV(uri: 'https://dav.example.com/dav', user: 'meow', password: 'secret', fileName: 'a.zip')),
    );
    expect(find.text('meow'), findsOneWidget);
    expect(find.text('a.zip'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);

    await _tapRow(tester, '文件');
    await tester.enterText(find.byType(TextFormField), 'meowx.zip');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(_container(tester).read(appDAVSettingProvider)?.fileName, 'meowx.zip');

    await _tapRow(tester, '文件');
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(_container(tester).read(appDAVSettingProvider)?.fileName, defaultDavFileName);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('开发者：开关写回 developerMode；清除数据要确认', (tester) async {
    await _pump(tester, const DeveloperPage(), _overrides());
    await _tapRow(tester, '开发者模式');
    expect(_container(tester).read(appSettingProvider).developerMode, isTrue);
    await _tapRow(tester, '清除数据');
    expect(find.text('危险操作'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('危险操作'), findsNothing);
  });

  testWidgets('语言 / 回环解锁：行能摆出来，语言按原顺序列出、选了写 locale', (tester) async {
    await _pump(
      tester,
      const MeSubPage.list(title: '设置', children: [MeSection(children: [LanguageRow(), LoopbackRow()])]),
      _overrides(app: const AppSettingProps(locale: 'zh_CN')),
    );
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('回环解锁工具'), findsOneWidget);
    await _tapRow(tester, '语言');
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(_container(tester).read(appSettingProvider).locale, 'en');
  });

  test('回环解锁工具只在程序目录里有 WindowsLoopbackManager.exe 时才有', () {
    expect(loopbackManagerExists, isFalse);
  });
}
