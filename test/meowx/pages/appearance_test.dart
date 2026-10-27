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
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
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

/// 「我的 › 外观」底部卡片的入口：一个按钮点开卡片。[glass] = 液态玻璃主题、外层有玻璃宿主（同 App 里包在 Navigator 外面）。
Future<void> _pump(
  WidgetTester tester, {
  MeowSettings meow = const MeowSettings(),
  bool glass = false,
  ThemeProps theme = const ThemeProps(),
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meowSettingProvider.overrideWith(() => _Meow(meow)),
        themeSettingProvider.overrideWith(() => _Theme(theme)),
        ...overrides,
      ],
      // 同 application.dart：主题按外观推 token（顺带让设置一直有人听着，不被自动回收）
      child: Consumer(
        builder: (_, ref, home) => MaterialApp(
          theme: meowThemeData(brightness: Brightness.light, look: ref.watch(meowLookProvider)),
          builder: (_, nav) => MeowGlassControls(
            enabled: glass,
            child: LiquidGlassScope(enabled: true, child: LiquidGlassHost(enabled: true, child: nav!)),
          ),
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

void main() {
  testWidgets('外观卡片：主题风格 / 卡片颜色两行；选液态玻璃才出现「玻璃样式」；改的都进设置', (tester) async {
    await _pump(tester);
    expect(find.text('主题风格'), findsOneWidget);
    expect(find.text('卡片颜色'), findsOneWidget);
    expect(find.text('白'), findsOneWidget, reason: '当前卡片色写在行尾');
    expect(find.text('玻璃样式'), findsNothing, reason: '经典主题下不出现');
    expect(find.byType(MeowGlassBox), findsNothing, reason: '经典主题：卡片仍是贴边的实色');

    await tester.tap(find.text('液态玻璃'));
    await tester.pumpAndSettle();
    expect(_settings(tester).themeStyle, MeowThemeStyle.glass);
    expect(find.text('玻璃样式'), findsOneWidget);

    await tester.tap(find.text('着色'));
    await tester.pumpAndSettle();
    expect(_settings(tester).glassTint, MeowGlassTint.tinted);

    // 卡片颜色 / 启动卡片颜色都有「薄荷」：按行找
    Finder swatch(MeowColorKind kind, String label) =>
        find.descendant(of: find.byWidgetPredicate((w) => w is ColorChoiceRow && w.kind == kind), matching: find.byTooltip(label));
    // 液态玻璃下「卡片颜色」那一行换成「底色」（单色 / 渐变）
    expect(find.text('卡片颜色'), findsNothing);
    expect(find.text('底色'), findsOneWidget);
    Finder bgSwatch(String label) => find.descendant(of: find.byType(GlassBgRow), matching: find.byTooltip(label));
    await tester.tap(bgSwatch('薄荷'));
    await tester.pumpAndSettle();
    expect(_settings(tester).cardColor, 0xFFECF8F1);
    expect(find.text('薄荷'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(GlassBgRow), matching: find.text('渐变')));
    await tester.pumpAndSettle();
    expect(_settings(tester).bgStyle, MeowBgStyle.gradient);
    expect(find.text('樱粉 · 薰衣草'), findsOneWidget, reason: '缺省的渐变写在行尾');
    await tester.tap(bgSwatch('薄荷 · 雾蓝'));
    await tester.pumpAndSettle();
    expect((_settings(tester).bgGradientFrom, _settings(tester).bgGradientTo), (0xFFCDEBDD, 0xFFCFDDF3));
    expect(_settings(tester).cardColor, 0xFFECF8F1, reason: '单色底色留着');

    await tester.ensureVisible(swatch(MeowColorKind.hero, '雾蓝'));
    await tester.tap(swatch(MeowColorKind.hero, '雾蓝'));
    await tester.pumpAndSettle();
    expect(_settings(tester).heroColor, 0xFFCFDDF3);

    await tester.ensureVisible(swatch(MeowColorKind.accent, '蓝'));
    await tester.tap(swatch(MeowColorKind.accent, '蓝'));
    await tester.pumpAndSettle();
    expect(_settings(tester).accentColor, 0xFF2F6FD0);
    expect(find.text('雾蓝'), findsOneWidget);

    await tester.ensureVisible(find.text('经典'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('经典'));
    await tester.pumpAndSettle();
    expect(_settings(tester).themeStyle, MeowThemeStyle.classic);
    expect(find.text('玻璃样式'), findsNothing);
    expect(_settings(tester).glassTint, MeowGlassTint.tinted, reason: '玻璃样式的选择留着，下次切回液态玻璃还是它');
    expect(find.text('卡片颜色'), findsOneWidget, reason: '经典主题下回到「卡片颜色」');
  });

  testWidgets('自定义渐变底色：切起始色 / 结束色分别取色，确定后存两种颜色并切到渐变', (tester) async {
    await _pump(tester, meow: const MeowSettings(themeStyle: MeowThemeStyle.glass, bgStyle: MeowBgStyle.gradient), glass: true);
    await tester.tap(find.descendant(of: find.byType(GlassBgRow), matching: find.byTooltip('自定义')));
    await tester.pumpAndSettle();
    expect(find.text('自定义渐变底色'), findsOneWidget);
    expect(find.byType(GradientPreview), findsOneWidget);
    await tester.enterText(find.byType(TextField), '112233');
    await tester.pumpAndSettle();
    await tester.tap(find.text('结束色（右下）'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '445566');
    await tester.pumpAndSettle();
    await tester.tap(find.text('起始色（左上）'));
    await tester.pumpAndSettle();
    expect(find.text('112233'), findsOneWidget, reason: '切回起始色，输入框显示它');
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();
    final s = _settings(tester);
    expect((s.bgStyle, s.bgGradientFrom, s.bgGradientTo), (MeowBgStyle.gradient, 0xFF112233, 0xFF445566));
    expect(find.text('自定义渐变'), findsOneWidget);
  });

  testWidgets('自定义卡片颜色：在卡片里进下一层取色（网格 / 光谱 / 滑块 + 十六进制），确定后存下并退回', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('自定义').first);
    await tester.pumpAndSettle();
    expect(find.text('自定义卡片颜色'), findsOneWidget);
    for (final mode in ['网格', '光谱', '滑块']) {
      expect(find.text(mode), findsOneWidget);
    }
    expect(find.byType(ColorPreview), findsOneWidget);

    await tester.tap(find.text('滑块'));
    await tester.pumpAndSettle();
    expect(find.text('色相'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'abcdef');
    await tester.pump();
    expect(find.text('ABCDEF'), findsOneWidget);
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();
    expect(_settings(tester).cardColor, 0xFFABCDEF);
    expect(find.text('自定义卡片颜色'), findsNothing, reason: '确定后退回外观这一层');
    expect(find.text('自定义 #ABCDEF'), findsOneWidget);

    // 强调色的自定义：同一个取色器
    await tester.ensureVisible(find.byTooltip('自定义').last);
    await tester.tap(find.byTooltip('自定义').last);
    await tester.pumpAndSettle();
    expect(find.text('自定义强调色'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2e7d4f');
    await tester.pump();
    await tester.tap(find.byTooltip('确定'));
    await tester.pumpAndSettle();
    expect(_settings(tester).accentColor, 0xFF2E7D4F);
  });

  testWidgets('液态玻璃：底部卡片浮起来（左右与底边留 8、圆角 38、玻璃底），里面的分组卡是半透明白', (tester) async {
    await _pump(tester, meow: const MeowSettings(themeStyle: MeowThemeStyle.glass), glass: true);
    final glass = find.byWidgetPredicate((w) => w is MeowGlassBox && w.radius == BorderRadius.circular(38));
    expect(glass, findsOneWidget);
    final rect = tester.getRect(glass);
    expect(rect.left, 8);
    expect(rect.right, _phone.width - 8);
    expect(rect.bottom, _phone.height - 8);
    expect(tester.widget<MeowGlassBox>(glass).rim, isNotNull);

    final section = tester.widget<Material>(
      find.descendant(of: find.byType(MeSection), matching: find.byType(Material)).first,
    );
    expect(section.color, MeowGlassSpec.light.panel);
  });

  testWidgets('经典：底部卡片仍贴边、实色，分组卡是卡片底', (tester) async {
    await _pump(tester, meow: const MeowSettings(cardColor: 0xFFFFEFF4));
    final section = tester.widget<Material>(
      find.descendant(of: find.byType(MeSection), matching: find.byType(Material)).first,
    );
    expect(section.color, MeowTokens.cardShades(const Color(0xFFFFEFF4), dark: false).card);
    final sheet = tester.getRect(find.ancestor(of: find.byType(MeSheetScope).first, matching: find.byType(GestureDetector)).last);
    expect(sheet.left, 0);
    expect(sheet.bottom, _phone.height);
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
    });
  });

  group('玻璃宿主', () {
    Future<(bool controls, bool scope)> probe(WidgetTester tester, {required MeowLook look, bool wide = false}) async {
      late bool controls, scope;
      await tester.pumpWidget(
        ProviderScope(
          // 每次一个新容器：overrideWith 只在容器建立时读一次
          key: UniqueKey(),
          overrides: [
            meowLookProvider.overrideWith((ref) => look),
            isWideLayoutProvider.overrideWithValue(wide),
          ],
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

    tearDown(() => MeowGlassDevice.debugLowEnd = false);

    testWidgets('手机：底栏两种主题都是玻璃（宿主恒开）；玻璃控件只在液态玻璃主题下开', (tester) async {
      expect(await probe(tester, look: MeowLook.classic), (false, true));
      expect(await probe(tester, look: const MeowLook(style: MeowThemeStyle.glass)), (true, true));
    });

    testWidgets('宽屏：经典主题一层都不多（宿主关），液态玻璃才开', (tester) async {
      expect(await probe(tester, look: MeowLook.classic, wide: true), (false, false));
      expect(await probe(tester, look: const MeowLook(style: MeowThemeStyle.glass), wide: true), (true, true));
    });

    testWidgets('低端机：玻璃控件退回实色（底栏照旧）', (tester) async {
      MeowGlassDevice.debugLowEnd = true;
      expect(await probe(tester, look: const MeowLook(style: MeowThemeStyle.glass)), (false, true));
      expect(await probe(tester, look: const MeowLook(style: MeowThemeStyle.glass), wide: true), (false, false));
    });
  });
}
