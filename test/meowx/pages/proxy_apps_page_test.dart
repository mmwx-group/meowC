import 'dart:async';

import 'package:bett_box/controller.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/pages/settings/proxy_apps_page.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _packages = [
  Package(
    packageName: 'com.example.alpha',
    label: 'Alpha',
    system: false,
    internet: true,
  ),
  Package(
    packageName: 'com.example.beta',
    label: 'Beta',
    system: false,
    internet: true,
  ),
  Package(
    packageName: 'com.example.gamma',
    label: 'Gamma',
    system: false,
    internet: true,
  ),
];

// 保留真实状态更新与页面交互，仅隔离全局配置写入和原生应用列表。
class _TestVpnSetting extends VpnSetting {
  _TestVpnSetting(this.initialAccess);

  final AccessControl initialAccess;

  @override
  VpnProps build() => VpnProps(accessControl: initialAccess);

  @override
  void onUpdate(VpnProps value) {}
}

class _TestPackages extends Packages {
  _TestPackages(this.initial);

  final List<Package> initial;

  @override
  List<Package> build() => initial;

  @override
  void onUpdate(List<Package> value) {}
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  AccessControl access, {
  List<Package> packages = _packages,
}) async {
  final wasInitialized = globalState.isInit;
  final previousController = wasInitialized ? globalState.appController : null;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (previousController != null) {
      globalState.appController = previousController;
    }
    // 现有 setter 不接受 null；未初始化时的控制器引用由下个用例覆盖。
    globalState.isInit = wasInitialized;
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        vpnSettingProvider.overrideWith(() => _TestVpnSetting(access)),
        packagesProvider.overrideWith(() => _TestPackages(packages)),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, child) {
            globalState.appController = AppController(context, ref);
            return const ProxyAppsPage();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(ProxyAppsPage)));
}

Finder _rowOf(String packageName) =>
    find.ancestor(of: find.text(packageName), matching: find.byType(Row)).first;

Finder _checkboxFor(String packageName) =>
    find.descendant(of: _rowOf(packageName), matching: find.byType(Checkbox));

/// 一屏装不下的应用列表（行滚出去会被销毁）。
final _manyPackages = [
  for (var i = 0; i < 40; i++)
    Package(
      packageName: 'com.example.app${i.toString().padLeft(2, '0')}',
      label: 'App ${i.toString().padLeft(2, '0')}',
      system: false,
      internet: true,
    ),
];

/// 每个包一份不同的「图标」字节。测试环境不真解码，只看拿到的是哪一份。
Uint8List _iconOf(String packageName) =>
    Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, ...packageName.codeUnits]);

/// 接管原生通道：记下每个包取了几次图标；[hold] 里的包先不回（由用例自己放行）。
Map<String, int> _mockIcons({
  List<Package> packages = const [],
  Map<String, Completer<void>> hold = const {},
}) {
  final calls = <String, int>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app'), (call) async {
        switch (call.method) {
          case 'getPackages':
            return [for (final p in packages) p.toJson()];
          case 'getPackageIcon':
            final name = (call.arguments as Map)['packageName'] as String;
            calls[name] = (calls[name] ?? 0) + 1;
            await hold[name]?.future;
            return _iconOf(name);
        }
        fail('没预期的通道调用：${call.method}');
      });
  return calls;
}

/// 这一行现在显示的图标字节（还是占位图标时为 null）。
Uint8List? _shownIcon(WidgetTester tester, String packageName) {
  final images = find.descendant(
    of: _rowOf(packageName),
    matching: find.byType(Image),
  );
  if (images.evaluate().isEmpty) return null;
  final provider = tester.widget<Image>(images).image;
  return ((provider as ResizeImage).imageProvider as MemoryImage).bytes;
}

ScrollPosition _scroll(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app'), (call) async {
          expect(call.method, 'getPackageIcon');
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app'), null);
  });

  testWidgets('切换黑白名单后独立保存应用选择', (tester) async {
    final container = await _pumpPage(
      tester,
      const AccessControl(
        enable: true,
        mode: AccessControlMode.acceptSelected,
        acceptList: ['com.example.alpha'],
        rejectList: ['com.example.beta'],
      ),
    );

    await tester.tap(find.text('黑名单'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.alpha')).value,
      isFalse,
    );
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.beta')).value,
      isTrue,
    );

    await tester.tap(_checkboxFor('com.example.gamma'));
    await tester.pumpAndSettle();
    await tester.tap(_checkboxFor('com.example.beta'));
    await tester.pumpAndSettle();
    var access = container.read(vpnSettingProvider).accessControl;
    expect(access.acceptList, ['com.example.alpha']);
    expect(access.rejectList, ['com.example.gamma']);

    await tester.tap(find.text('白名单'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.alpha')).value,
      isTrue,
    );
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.gamma')).value,
      isFalse,
    );

    await tester.tap(_checkboxFor('com.example.alpha'));
    await tester.pumpAndSettle();
    access = container.read(vpnSettingProvider).accessControl;
    expect(access.acceptList, isEmpty);
    expect(access.rejectList, ['com.example.gamma']);

    await tester.tap(find.text('黑名单'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.gamma')).value,
      isTrue,
    );
  });

  testWidgets('关闭再开启保留黑名单模式和两份名单', (tester) async {
    const initialAccess = AccessControl(
      enable: true,
      mode: AccessControlMode.rejectSelected,
      acceptList: ['com.example.alpha'],
      rejectList: ['com.example.beta'],
    );
    final container = await _pumpPage(tester, initialAccess);

    await tester.tap(find.text('启用应用分流'));
    await tester.pumpAndSettle();
    expect(
      container.read(vpnSettingProvider).accessControl,
      initialAccess.copyWith(enable: false),
    );
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.text('启用应用分流'));
    await tester.pumpAndSettle();
    expect(container.read(vpnSettingProvider).accessControl, initialAccess);
    expect(
      tester
          .widget<MeowSegment<AccessControlMode>>(
            find.byType(MeowSegment<AccessControlMode>),
          )
          .value,
      AccessControlMode.rejectSelected,
    );
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.beta')).value,
      isTrue,
    );
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.alpha')).value,
      isFalse,
    );
  });

  testWidgets('进入页面直接呈现已保存的黑名单', (tester) async {
    await _pumpPage(
      tester,
      const AccessControl(
        enable: true,
        mode: AccessControlMode.rejectSelected,
        acceptList: ['com.example.alpha'],
        rejectList: ['com.example.beta', 'com.example.gamma'],
      ),
    );

    expect(
      tester
          .widget<MeowSegment<AccessControlMode>>(
            find.byType(MeowSegment<AccessControlMode>),
          )
          .value,
      AccessControlMode.rejectSelected,
    );
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.alpha')).value,
      isFalse,
    );
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.beta')).value,
      isTrue,
    );
    expect(
      tester.widget<Checkbox>(_checkboxFor('com.example.gamma')).value,
      isTrue,
    );
  });

  testWidgets('应用图标按包名只取一次：行滚出去再滚回来直接用取过的那份，首帧就有图', (tester) async {
    final calls = _mockIcons();
    const first = 'com.example.app00';
    await _pumpPage(
      tester,
      const AccessControl(enable: true),
      packages: _manyPackages,
    );
    expect(calls[first], 1);
    final shown = _shownIcon(tester, first);
    expect(shown, _iconOf(first));

    // 滚到底：第一行已经被销毁
    _scroll(tester).jumpTo(_scroll(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text(first), findsNothing);
    expect(calls['com.example.app39'], 1);

    // 滚回来只 pump 一帧：没有再走通道，也没有先闪占位图标；还是同一份字节对象（解码结果才能在图片缓存里命中）
    _scroll(tester).jumpTo(0);
    await tester.pump();
    expect(find.text(first), findsOneWidget);
    expect(calls[first], 1);
    expect(
      find.descendant(
        of: _rowOf(first),
        matching: find.byIcon(Icons.android_rounded),
      ),
      findsNothing,
    );
    expect(identical(_shownIcon(tester, first), shown), isTrue);
  });

  testWidgets('重新读取应用列表后图标重新取（应用更新后图标可能变了）', (tester) async {
    final calls = _mockIcons(packages: _manyPackages);
    const first = 'com.example.app00';
    await _pumpPage(
      tester,
      const AccessControl(enable: true),
      packages: _manyPackages,
    );
    expect(calls[first], 1);

    await tester.tap(find.byTooltip('重新读取应用列表'));
    await tester.pumpAndSettle();
    expect(find.text(first), findsOneWidget);

    _scroll(tester).jumpTo(_scroll(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    _scroll(tester).jumpTo(0);
    await tester.pumpAndSettle();
    expect(calls[first], 2);
    expect(_shownIcon(tester, first), _iconOf(first));
  });

  testWidgets('搜索后同一位置换成别的应用：图标没取回来前是占位，不沿用上一个应用的', (tester) async {
    const target = 'com.example.app39';
    final gate = Completer<void>();
    final calls = _mockIcons(hold: {target: gate});
    await _pumpPage(
      tester,
      const AccessControl(enable: true),
      packages: _manyPackages,
    );
    expect(_shownIcon(tester, 'com.example.app00'), isNotNull);
    expect(calls[target], isNull); // 最后一个应用还没滚到过

    await tester.enterText(find.byType(TextField), 'App 39');
    await tester.pump();
    expect(find.byType(Checkbox), findsOneWidget);
    expect(calls[target], 1);
    expect(_shownIcon(tester, target), isNull);
    expect(
      find.descendant(
        of: _rowOf(target),
        matching: find.byIcon(Icons.android_rounded),
      ),
      findsOneWidget,
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(_shownIcon(tester, target), _iconOf(target));

    // 清掉搜索词：先前显示过的行回来，各自还是自己的图标，也没有重新取
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(
      _shownIcon(tester, 'com.example.app00'),
      _iconOf('com.example.app00'),
    );
    expect(
      _shownIcon(tester, 'com.example.app01'),
      _iconOf('com.example.app01'),
    );
    expect(calls['com.example.app00'], 1);
  });

  testWidgets('图标取不到（通道报错 / 没有图标）时留着占位图标，不抛未处理的异常', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app'), (call) async {
          final name = (call.arguments as Map)['packageName'] as String;
          if (name == 'com.example.alpha') {
            throw PlatformException(code: 'boom');
          }
          return null;
        });
    await _pumpPage(tester, const AccessControl(enable: true));
    expect(find.byIcon(Icons.android_rounded), findsNWidgets(3));
    expect(find.byType(Image), findsNothing);
  });
}
