// globalState.corePalette 是 Bettbox 的 CorePalette（dynamic_color 给的类型），测试照它的类型构造
// ignore_for_file: deprecated_member_use
import 'package:bett_box/meowx/app/glass_host.dart';
import 'package:bett_box/meowx/glass/liquid_glass.dart';
import 'package:bett_box/meowx/pages/me/appearance_parts.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/pages/me/me_sheet.dart';
import 'package:bett_box/meowx/pages/me/settings_rows.dart';
import 'package:bett_box/meowx/state/app_icon.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/theme/glass.dart';
import 'package:bett_box/meowx/theme/m3.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// 设置 Notifier 换成不碰 globalState 落盘的替身（同 me_page_test）。

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Theme extends ThemeSetting {
  _Theme([this.initial = const ThemeProps()]);
  final ThemeProps initial;

  @override
  ThemeProps build() => initial;

  @override
  void onUpdate(ThemeProps value) {}
}

const _phone = Size(412, 892);

/// 原生图标切换的替身：记下每次调用，[ok] = false 时原生说没切成。
class _Bridge implements AppIconBridge {
  _Bridge(this.name, {this.ok = true});
  String? name;
  final bool ok;
  final calls = <String>[];

  @override
  Future<String?> current() async => name;

  @override
  Future<bool> set(String value) async {
    calls.add(value);
    if (ok) name = value;
    return ok;
  }
}

/// 「我的 › 外观」底部卡片的入口：一个按钮点开卡片。
Future<void> _pump(
  WidgetTester tester, {
  MeowSettings meow = const MeowSettings(),
  ThemeProps theme = const ThemeProps(),
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // BaseNavigator.push（设置页整页推入）按视口宽度选转场
  globalState.appState = AppState(
    viewSize: _phone,
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
        themeSettingProvider.overrideWith(() => _Theme(theme)),
        ...overrides,
      ],
      // 同 application.dart：主题按外观定种子色（顺带让设置一直有人听着，不被自动回收）
      child: Consumer(
        builder: (_, ref, home) => MaterialApp(
          theme: meowThemeData(brightness: Brightness.light, seed: meowSeedOf(ref.watch(meowLookProvider))),
          builder: (_, nav) => LiquidGlassScope(enabled: true, child: LiquidGlassHost(enabled: true, child: nav!)),
          home: home,
        ),
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showMeSheet(
                  context,
                  MeSubPage.list(title: '外观', children: const [MeSection(children: [AppearanceRows()])]),
                ),
                child: const Text('打开外观'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开外观'));
  await tester.pumpAndSettle();
}

MeowSettings _settings(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(AppearanceRows))).read(meowSettingProvider);

Finder _swatch(String label, {bool? selected}) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label && (selected == null || w.properties.selected == selected),
);

ColorScheme _scheme(WidgetTester tester) => Theme.of(tester.element(find.byType(AppearanceRows))).colorScheme;

void main() {
  tearDown(() => globalState.corePalette = null);

  testWidgets('外观卡片：主题色八个预设 + 自定义，缺省品牌玫瑰；点别的颜色存进设置、整套配色跟着换', (tester) async {
    await _pump(tester);
    expect(find.text('主题色'), findsOneWidget);
    expect(find.text('玫瑰'), findsOneWidget, reason: '当前主题色写在行尾');
    for (final (label, _) in MeowColors.presets) {
      expect(_swatch(label), findsOneWidget);
    }
    expect(_swatch('玫瑰', selected: true), findsOneWidget);
    expect(_swatch('自定义', selected: false), findsOneWidget);
    expect(find.text('跟随系统取色'), findsNothing, reason: '取不到系统色板时不出现');
    expect(_scheme(tester).primary, MeowColors.scheme(MeowColors.brandSeed, Brightness.light).primary);

    await tester.tap(_swatch('海洋'));
    await tester.pumpAndSettle();
    expect(_settings(tester).accentColor, 0xFF2D6FB0);
    expect(_swatch('海洋', selected: true), findsOneWidget);
    expect(_swatch('玫瑰', selected: false), findsOneWidget);
    expect(_scheme(tester).primary, MeowColors.scheme(const Color(0xFF2D6FB0), Brightness.light).primary);
  });

  testWidgets('跟随系统取色：有系统色板时出现；打开后用系统色板生成配色，主题色那一行变灰、点不动', (tester) async {
    globalState.corePalette = CorePalette.of(0xFF2E8B6E);
    await _pump(tester);
    expect(find.text('跟随系统取色'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(FollowSystemColorRow), matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(_settings(tester).followSystemColor, isTrue);
    expect(find.textContaining('正在跟随系统取色'), findsOneWidget, reason: '主题色那一行的说明换掉');
    expect(_scheme(tester).primary, MeowColors.scheme(Color(globalState.corePalette!.primary.get(40)), Brightness.light).primary);

    await tester.tap(_swatch('海洋'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_settings(tester).accentColor, MeowColors.brandSeed.toARGB32(), reason: '跟随系统时预设点不动');
  });

  test('种子色：跟随系统但取不到系统色时退回设置里的主题色', () {
    expect(meowSeedOf(const MeowLook(seed: 0xFF2D6FB0)), const Color(0xFF2D6FB0));
    expect(meowSeedOf(const MeowLook(seed: 0xFF2D6FB0, followSystem: true)), const Color(0xFF2D6FB0));
    globalState.corePalette = CorePalette.of(0xFF2E8B6E);
    expect(meowSeedOf(const MeowLook(seed: 0xFF2D6FB0, followSystem: true)), Color(globalState.corePalette!.primary.get(40)));
  });

  testWidgets('自定义主题色：在卡片里进下一层取色（网格 / 光谱 / 滑块 + 十六进制 + 浅深两份预览），确定后存下并退回', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('自定义'));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsOneWidget);
    for (final mode in ['网格', '光谱', '滑块']) {
      expect(find.text(mode), findsOneWidget);
    }
    expect(find.byType(SchemePreview), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'abcdef');
    await tester.pump();
    expect(find.text('ABCDEF'), findsOneWidget);
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();
    expect(_settings(tester).accentColor, 0xFFABCDEF);
    expect(find.text('自定义主题色'), findsNothing, reason: '确定后退回外观这一层');
    expect(find.text('自定义 #ABCDEF'), findsOneWidget);
    expect(_swatch('自定义', selected: true), findsOneWidget);
  });

  group('App 图标', () {
    Finder choice(String label, {bool? selected}) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label && (selected == null || w.properties.selected == selected),
    );

    Future<_Bridge> pumpIcons(WidgetTester tester, {String? native = 'default', bool ok = true, bool legacyDark = false}) async {
      final bridge = _Bridge(native, ok: ok);
      await _pump(
        tester,
        theme: ThemeProps(useDarkIcon: legacyDark),
        overrides: [appIconSupportedProvider.overrideWithValue(true), appIconBridgeProvider.overrideWithValue(bridge)],
      );
      await tester.ensureVisible(find.text('App 图标'));
      await tester.pumpAndSettle();
      return bridge;
    }

    testWidgets('非 Android 不出现', (tester) async {
      await _pump(tester);
      expect(find.text('App 图标'), findsNothing);
    });

    testWidgets('三个选项并排；当前值按原生查到的选中，点了交给原生、选中态跟过去', (tester) async {
      final bridge = await pumpIcons(tester, native: 'm_dark');
      for (final label in ['默认', 'M · 深色', 'M · 浅色']) {
        expect(choice(label), findsOneWidget);
      }
      expect(choice('M · 深色', selected: true), findsOneWidget);
      final rows = {for (final l in ['默认', 'M · 深色', 'M · 浅色']) tester.getRect(choice(l)).top};
      expect(rows, hasLength(1), reason: '一行并排');

      await tester.tap(choice('M · 浅色'));
      await tester.pumpAndSettle();
      expect(bridge.calls, ['m_light']);
      expect(choice('M · 浅色', selected: true), findsOneWidget);
      expect(choice('M · 深色', selected: false), findsOneWidget);

      await tester.tap(choice('M · 浅色'));
      await tester.pumpAndSettle();
      expect(bridge.calls, ['m_light'], reason: '点当前那个不再调原生');

      await tester.tap(choice('默认'));
      await tester.pumpAndSettle();
      expect(bridge.calls.last, 'default');
      expect(choice('默认', selected: true), findsOneWidget);
    });

    testWidgets('Bettbox 的「深色图标」开着：猫娘算「默认」，切回默认时开深色那个', (tester) async {
      final bridge = await pumpIcons(tester, native: 'dark', legacyDark: true);
      expect(choice('默认', selected: true), findsOneWidget);
      await tester.tap(choice('M · 深色'));
      await tester.pumpAndSettle();
      await tester.tap(choice('默认'));
      await tester.pumpAndSettle();
      expect(bridge.calls, ['m_dark', 'dark']);
    });

    testWidgets('原生没切成功：选中态退回', (tester) async {
      final bridge = await pumpIcons(tester, ok: false);
      await tester.tap(choice('M · 深色'));
      await tester.pumpAndSettle();
      expect(bridge.calls, ['m_dark']);
      expect(choice('默认', selected: true), findsOneWidget);
      expect(choice('M · 深色', selected: false), findsOneWidget);
    });

    test('原生组件名对照', () {
      expect(MeowAppIcon.fromNative('default'), MeowAppIcon.catgirl);
      expect(MeowAppIcon.fromNative('light'), MeowAppIcon.catgirl);
      expect(MeowAppIcon.fromNative('dark'), MeowAppIcon.catgirl);
      expect(MeowAppIcon.fromNative(null), MeowAppIcon.catgirl);
      expect(MeowAppIcon.fromNative('m_dark'), MeowAppIcon.mDark);
      expect(MeowAppIcon.fromNative('m_light'), MeowAppIcon.mLight);
      expect(MeowAppIcon.mLight.nativeName(legacyDark: true), 'm_light');
      // 「X」三款：原生名来回对得上
      for (final v in [MeowAppIcon.xDuo, MeowAppIcon.xInk, MeowAppIcon.xGradient]) {
        expect(MeowAppIcon.fromNative(v.nativeName(legacyDark: false)), v);
      }
      expect(MeowAppIcon.xGradient.nativeName(legacyDark: true), 'x_gradient');
    });
  });

  group('玻璃宿主', () {
    Future<(bool controls, bool scope)> probe(WidgetTester tester, {bool wide = false}) async {
      late bool controls, scope;
      await tester.pumpWidget(
        ProviderScope(
          // 每次一个新容器：overrideWith 只在容器建立时读一次
          key: UniqueKey(),
          overrides: [isWideLayoutProvider.overrideWithValue(wide)],
          child: MaterialApp(
            home: MeowGlassHost(
              child: Builder(
                builder: (context) {
                  controls = MeowGlassControls.of(context);
                  scope = LiquidGlassScope.of(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      return (controls, scope);
    }

    testWidgets('手机：底栏是玻璃（宿主开）；页面上的控件不再是玻璃', (tester) async {
      expect(await probe(tester), (false, true));
    });

    testWidgets('宽屏：没有底栏，宿主关', (tester) async {
      expect(await probe(tester, wide: true), (false, false));
    });
  });
}
