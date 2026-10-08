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
  @override
  List<Package> build() => _packages;

  @override
  void onUpdate(List<Package> value) {}
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  AccessControl access,
) async {
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
        packagesProvider.overrideWith(_TestPackages.new),
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

Finder _checkboxFor(String packageName) => find.descendant(
  of: find
      .ancestor(of: find.text(packageName), matching: find.byType(Row))
      .first,
  matching: find.byType(Checkbox),
);

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
}
