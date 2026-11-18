import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/meowx/pages/advanced/tools/requests_page.dart';
import 'package:bett_box/meowx/pages/advanced/tools/resources_page.dart';
import 'package:bett_box/meowx/pages/advanced/tools/scripts_page.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/theme/m3_kit.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/haptics.dart';

// 三页（脚本 / 资源 / 请求记录）的布局与基本交互：Notifier 换成不碰 globalState 落盘 / 核心 / 网络的替身。

class _Scripts extends ScriptState {
  _Scripts(this.initial);
  final ScriptProps initial;

  @override
  ScriptProps build() => initial;

  @override
  void onUpdate(ScriptProps value) {}
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
  @override
  String? build() => null;

  @override
  void onUpdate(String? value) {}
}

class _Patch extends PatchClashConfig {
  @override
  ClashConfig build() => const ClashConfig();

  @override
  void onUpdate(ClashConfig value) {}
}

class _Requests extends Requests {
  _Requests(this.initial);
  final List<TrackerInfo> initial;

  @override
  FixedList<TrackerInfo> build() => FixedList(1000, list: [...initial]);

  @override
  void onUpdate(FixedList<TrackerInfo> value) {}
}

class _Loading extends Loading {
  @override
  bool build() => false;

  @override
  void onUpdate(bool value) {}
}

List<Override> _overrides({
  ScriptProps scripts = const ScriptProps(),
  List<Profile> profiles = const [],
  List<TrackerInfo> requests = const [],
}) => [
  scriptStateProvider.overrideWith(() => _Scripts(scripts)),
  profilesProvider.overrideWith(() => _Profiles(profiles)),
  currentProfileIdProvider.overrideWith(_ProfileId.new),
  patchClashConfigProvider.overrideWith(_Patch.new),
  requestsProvider.overrideWith(() => _Requests(requests)),
  loadingProvider.overrideWith(_Loading.new),
];

const _phone = Size(360, 800);

/// 按给定窗口尺寸与文字缩放摆出来（溢出会作为异常让用例失败）。
Future<void> _pump(WidgetTester tester, Widget child, {required List<Override> overrides, Size size = _phone}) async {
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
  await tester.pumpWidget(const SizedBox.shrink());
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

/// 页面里真实的文件读取（appPath → lastModified → length）一环接一环：每环都要真的等一下 IO、再 pump 把回调放出来
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MeSubPage).first));

const _longJs = '// Compatible_With_Bettbox\nfunction main(config) { return config }';

final _scripts = ScriptProps(
  currentId: 's2',
  scripts: [
    const Script(id: 's1', label: '一个名字特别特别特别特别长的覆写脚本（去广告 + 分流 + 规则补全）', content: 'function main(c){return c}'),
    const Script(
      id: 's2',
      label: '远程脚本',
      content: _longJs,
      url: 'https://raw.githubusercontent.com/example/repo/main/override.js',
    ),
    const Script(id: 's3', label: 'local.js', content: 'function main(c){return c}'),
  ],
);

TrackerInfo _req(int i, {List<String>? chains}) => TrackerInfo(
  id: 'r$i',
  upload: 1800 * i,
  download: 462000 * i,
  start: DateTime.now().subtract(Duration(seconds: i * 7)),
  metadata: Metadata(
    network: i.isEven ? 'tcp' : 'udp',
    host: i % 3 == 0 ? 'a-very-long-subdomain-$i.of.some.really-long-host-name.api.bilibili.com' : 'host$i.example.com',
    destinationIP: '198.51.100.${i % 250}',
    destinationPort: '443',
    sourceIP: '172.19.0.1',
    sourcePort: '${50000 + i}',
    process: i.isEven ? 'com.example.app$i' : '',
    remoteDestination: '203.0.113.9:443',
  ),
  chains:
      chains ??
      (i == 40
          ? ['香港 01 · IEPL 专线超长名字节点', '自动选择', '节点选择']
          : i.isEven
          ? ['香港 01', '自动选择', '节点选择']
          : ['DIRECT']),
  rule: 'RuleSet',
  rulePayload: 'proxy-list',
);

void main() {
  late Directory home;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    home = Directory.systemTemp.createTempSync('meowx_tools_test');
    // appPath 首次用到时向 path_provider 要数据目录：给一个临时目录，并在测试的假时钟之外先把它要到手
    // （在 testWidgets 里第一次碰 appPath 的话，数据目录的回调落在那个用例的假时钟里，之后的用例等不到）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => home.path,
    );
    await appPath.homeDirPath;
  });

  tearDownAll(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  group('脚本', () {
    testWidgets('空状态：窄屏 1.4 倍字号不溢出', (tester) async {
      await _pump(tester, const ScriptsPage(), overrides: _overrides());
      expect(find.text('脚本'), findsWidgets);
      expect(find.text('暂无脚本 · 点右上角「+」导入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有数据：三行不溢出；选中的那行开关打开；点开关切换启用的脚本', (tester) async {
      recordHaptics();
      await _pump(tester, const ScriptsPage(), overrides: _overrides(scripts: _scripts));
      expect(find.byType(Switch), findsNWidgets(3));
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect([for (final s in switches) s.value], [false, true, false]);
      expect(find.text('raw.githubusercontent.com · 可自定义'), findsOneWidget);
      expect(find.text('本地脚本'), findsNWidgets(2));

      await tester.tap(find.byType(Switch).at(2));
      await tester.pump();
      expect(_container(tester).read(scriptStateProvider).currentId, 's3');

      // 关掉当前启用的 = 取消选中
      await tester.tap(find.byType(Switch).at(2));
      await tester.pump();
      expect(_container(tester).read(scriptStateProvider).currentId, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('「更多」菜单：可自定义的才有「自定义选项」、有地址的才有「同步」', (tester) async {
      await _pump(tester, const ScriptsPage(), overrides: _overrides(scripts: _scripts));
      await tester.tap(find.byTooltip('更多').at(1));
      await tester.pumpAndSettle();
      expect(find.text('自定义选项'), findsOneWidget);
      expect(find.text('同步'), findsOneWidget);
      expect(find.text('导出文件'), findsOneWidget);
      await tester.tapAt(const Offset(5, 790));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多').at(0));
      await tester.pumpAndSettle();
      expect(find.text('自定义选项'), findsNothing);
      expect(find.text('同步'), findsNothing);
      expect(find.text('编辑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除先确认，按名字删掉', (tester) async {
      await _pump(tester, const ScriptsPage(), overrides: _overrides(scripts: _scripts));
      await tester.tap(find.byTooltip('更多').at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确定删除脚本「local.js」'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect([for (final s in _container(tester).read(scriptStateProvider).scripts) s.id], ['s1', 's2']);
    });

    testWidgets('全局脚本覆写：没有配置文件 / 有配置文件都不溢出', (tester) async {
      await _pump(tester, const ScriptOverridePage(), overrides: _overrides());
      expect(find.text('没有配置文件，请先添加配置文件'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _pump(
        tester,
        const ScriptOverridePage(),
        overrides: _overrides(
          profiles: [
            const Profile(
              id: 'p1',
              label: '主力订阅（名字很长很长很长很长很长很长的机场）',
              autoUpdateDuration: Duration(hours: 1),
              useScriptOverride: true,
            ),
            const Profile(id: 'p2', autoUpdateDuration: Duration(hours: 1), useScriptOverride: false),
          ],
        ),
      );
      expect(find.byType(Switch), findsNWidgets(2));
      await tester.tap(find.byType(Switch).last);
      await tester.pump();
      final p2 = _container(tester).read(profilesProvider).firstWhere((p) => p.id == 'p2');
      expect(p2.useScriptOverride, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('自定义选项页：有选项 / 没选项不溢出；改了才能保存', (tester) async {
      await _pump(
        tester,
        ScriptOptionsPage(
          script: _scripts.scripts[1],
          initialOptions: const {'去广告': true, '一个特别特别特别特别特别长的分流开关名字': false, 'YouTube': true},
          icons: const {},
        ),
        overrides: _overrides(scripts: _scripts),
      );
      expect(find.byType(Switch), findsNWidgets(3));
      // 没改动时保存钮不可点；改一项后可点
      M3IconButton saveButton() => tester.widget<M3IconButton>(find.widgetWithIcon(M3IconButton, Icons.save_outlined));
      expect(saveButton().onPressed, isNull);
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(saveButton().onPressed, isNotNull);
      expect(tester.takeException(), isNull);

      await _pump(
        tester,
        ScriptOptionsPage(script: _scripts.scripts[1], initialOptions: const {}, icons: const {}),
        overrides: _overrides(scripts: _scripts),
      );
      expect(find.text('这个脚本没有读到可自定义的选项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('资源', () {
    testWidgets('本机还没有数据文件：四项都在、不溢出', (tester) async {
      await _pump(tester, const ResourcesPage(), overrides: _overrides());
      await _settleIo(tester);
      for (final label in ['GeoSite', 'MMDB', 'ASN', 'MRS']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('本机还没有这个文件'), findsNWidgets(4));
      expect(find.byTooltip('同步'), findsNWidgets(3));
      expect(find.byTooltip('修改下载地址'), findsNWidgets(3));
      expect(find.text('内置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有数据文件：显示大小与更新时间，不溢出', (tester) async {
      for (final name in [geoSiteFileName, mmdbFileName, asnFileName, bundleMRSFileName]) {
        File('${home.path}/$name').writeAsBytesSync(List.filled(2048, 1));
      }
      addTearDown(() {
        for (final name in [geoSiteFileName, mmdbFileName, asnFileName, bundleMRSFileName]) {
          final f = File('${home.path}/$name');
          if (f.existsSync()) f.deleteSync();
        }
      });
      await _pump(tester, const ResourcesPage(), overrides: _overrides());
      await _settleIo(tester);
      expect(find.text('本机还没有这个文件'), findsNothing);
      expect(find.textContaining('内置', findRichText: true), findsWidgets);
      expect(find.textContaining('·'), findsNWidgets(4));
      expect(find.text(const GeoXUrl().geosite), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('请求记录', () {
    testWidgets('空状态：不溢出', (tester) async {
      await _pump(tester, const RequestsPage(), overrides: _overrides());
      expect(find.text('暂无请求'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有数据：分段清单不溢出，新的在最上面；点代理链加筛选、去掉筛选恢复', (tester) async {
      final reqs = [for (var i = 1; i <= 40; i++) _req(i)];
      await _pump(tester, const RequestsPage(), overrides: _overrides(requests: reqs));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // 倒排：最新一条（第 40 条）画在最上面
      final first = tester.getTopLeft(find.text(reqs.last.desc));
      final second = tester.getTopLeft(find.text(reqs[38].desc));
      expect(first.dy, lessThan(second.dy));

      await tester.tap(find.text('自动选择').hitTestable().first);
      await tester.pump();
      await tester.pump();
      expect(find.byType(InputChip), findsOneWidget);
      expect(_container(tester).read(filteredRequestsProvider).length, 20);
      expect(find.text('DIRECT'), findsNothing);

      await tester.tap(find.byTooltip('去掉这个筛选'));
      await tester.pump();
      expect(find.byType(InputChip), findsNothing);
      expect(_container(tester).read(filteredRequestsProvider).length, 40);
      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索没有匹配时提示；点一行打开详情不溢出', (tester) async {
      final reqs = [for (var i = 1; i <= 5; i++) _req(i)];
      await _pump(tester, const RequestsPage(), overrides: _overrides(requests: reqs));
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'no-such-host');
      await tester.pump();
      expect(find.text('没有匹配的请求'), findsOneWidget);
      await tester.tap(find.byTooltip('收起搜索'));
      await tester.pump();
      expect(find.text(reqs.last.desc), findsOneWidget);

      await tester.tap(find.text(reqs[2].desc));
      await tester.pumpAndSettle();
      expect(find.text('详情'), findsOneWidget);
      expect(find.text('代理链'), findsOneWidget);
      expect(find.text('RuleSet(proxy-list)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('清空：列表回到空状态', (tester) async {
      await _pump(tester, const RequestsPage(), overrides: _overrides(requests: [_req(1), _req(2)]));
      await tester.tap(find.byTooltip('清空'));
      await tester.pump();
      await tester.pump();
      expect(find.text('暂无请求'), findsOneWidget);
    });
  });
}
