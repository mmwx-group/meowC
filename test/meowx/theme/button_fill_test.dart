import 'package:bett_box/meowx/glass/liquid_glass.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/theme/button_fill.dart';
import 'package:bett_box/meowx/theme/glass.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/page_title.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _glassLook = MeowLook(style: MeowThemeStyle.glass);

MeowTokens _glass(bool dark) => MeowTokens.resolve(dark ? Brightness.dark : Brightness.light, _glassLook);

/// [host] = 外面套着玻璃宿主（画得了玻璃控件）；液态玻璃主题但没有宿主 = 低端机的样子
Widget _app(Widget child, {MeowLook look = MeowLook.classic, bool host = false}) => MaterialApp(
  theme: meowThemeData(brightness: Brightness.light, look: look),
  builder: host
      ? (_, nav) => MeowGlassControls(
          enabled: true,
          child: LiquidGlassScope(
            enabled: true,
            quality: LiquidGlassQuality.standard,
            child: LiquidGlassHost(enabled: true, child: nav!),
          ),
        )
      : null,
  home: Scaffold(body: Center(child: child)),
);

void _expectSameColor(Color a, Color b) {
  expect(a.a, closeTo(b.a, 1e-6));
  expect(a.r, closeTo(b.r, 1e-6));
  expect(a.g, closeTo(b.g, 1e-6));
  expect(a.b, closeTo(b.b, 1e-6));
}

void main() {
  group('按钮底', () {
    test('经典主题：各档就是各调用点原来的实色、没有描边，字色是页面底色（换了卡片色也一样）', () {
      for (final mm in [
        MeowTokens.light,
        MeowTokens.dark,
        MeowTokens.resolve(Brightness.light, const MeowLook(cardColor: 0xFFECF8F1, accentColor: 0xFF2F6FD0)),
      ]) {
        expect(mm.glass, isFalse);
        expect(mm.buttonFill(MeowButtonFill.prominent), mm.t1);
        expect(mm.buttonFill(MeowButtonFill.selected), mm.t1);
        expect(mm.buttonFill(MeowButtonFill.accent), mm.soft);
        expect(mm.buttonFill(MeowButtonFill.plain), mm.elev);
        expect(mm.buttonFill(MeowButtonFill.secondary), mm.card2);
        expect(mm.buttonFill(MeowButtonFill.danger), mm.slow.withValues(alpha: 0.10));
        final blended = Color.alphaBlend(mm.soft, mm.elev);
        expect(mm.buttonFill(MeowButtonFill.accent, classic: blended), blended, reason: '调用点原来的颜色和缺省那档不一样时照旧');
        expect(mm.buttonSide, BorderSide.none);
        expect(mm.buttonBorder, isNull);
        expect(mm.onProminent, mm.bg);
        expect(mm.onSelected, mm.bg);
      }
    });

    test('液态玻璃：次级块那档白 + 一点主题色（主要 18% 墨色 / 强调 14% / 选中 22% 强调色 / 危险 14% 红）+ 0.8 细亮边', () {
      for (final dark in [false, true]) {
        final mm = _glass(dark);
        final base = Colors.white.withValues(alpha: dark ? 0.07 : 0.38);
        expect(mm.card2, base);
        expect(mm.buttonFill(MeowButtonFill.plain), base);
        expect(mm.buttonFill(MeowButtonFill.secondary), base);
        expect(mm.buttonFill(MeowButtonFill.prominent), Color.alphaBlend(mm.t1.withValues(alpha: 0.18), base));
        expect(mm.buttonFill(MeowButtonFill.accent), Color.alphaBlend(mm.accent.withValues(alpha: 0.14), base));
        expect(mm.buttonFill(MeowButtonFill.selected), Color.alphaBlend(mm.accent.withValues(alpha: 0.22), base));
        expect(mm.buttonFill(MeowButtonFill.danger), Color.alphaBlend(mm.slow.withValues(alpha: 0.14), base));
        expect(
          mm.buttonFill(MeowButtonFill.accent, classic: Colors.red),
          mm.buttonFill(MeowButtonFill.accent),
          reason: '经典色只管经典主题',
        );
        for (final k in MeowButtonFill.values) {
          expect(mm.buttonFill(k).a, lessThan(0.6), reason: '$k 是半透明的，不是实色块（dark: $dark）');
        }
        expect(mm.buttonSide, BorderSide(color: Colors.white.withValues(alpha: dark ? 0.16 : 0.7), width: 0.8));
        expect(mm.buttonBorder, Border.fromBorderSide(mm.buttonSide));
        expect(mm.onProminent, mm.t1);
        expect(mm.onSelected, mm.accent);
      }
    });

    test('叠成的一个颜色 = 先画次级块、再画色调（画在什么底上都一样）', () {
      final mm = _glass(false);
      for (final under in const [Color(0xFFFFFFFF), Color(0xFF223344), Color(0xFFF7CDDB)]) {
        _expectSameColor(
          Color.alphaBlend(mm.buttonFill(MeowButtonFill.prominent), under),
          Color.alphaBlend(mm.t1.withValues(alpha: 0.18), Color.alphaBlend(mm.card2, under)),
        );
      }
    });

    test('实心主按钮（FilledButton）的主题：经典 = 墨色底 + 页面底色的字；玻璃 = 静态半透明 + 细亮边 + 墨色字', () {
      final classic = meowThemeData(brightness: Brightness.light).filledButtonTheme.style!;
      expect(classic.backgroundColor!.resolve({}), MeowTokens.light.t1);
      expect(classic.foregroundColor!.resolve({}), MeowTokens.light.bg);
      expect(classic.side, isNull);

      final mm = _glass(false);
      final glass = meowThemeData(brightness: Brightness.light, look: _glassLook).filledButtonTheme.style!;
      expect(glass.backgroundColor!.resolve({}), mm.buttonFill(MeowButtonFill.prominent));
      expect(glass.foregroundColor!.resolve({}), mm.t1);
      expect(glass.side!.resolve({}), mm.buttonSide);
    });
  });

  group('按钮：液态玻璃 / 经典', () {
    testWidgets('页头的实底主操作（RoundGlassButton filled）：经典墨色实心；玻璃下（有没有宿主都）是静态半透明 + 墨色图标', (tester) async {
      Widget btn() => RoundGlassButton(icon: Icons.bolt, filled: true, tooltip: '测速', onTap: () {});
      Material material() =>
          tester.widget<Material>(find.descendant(of: find.byType(RoundGlassButton), matching: find.byType(Material)).first);
      Color? icon() => tester.widget<Icon>(find.byIcon(Icons.bolt)).color;

      await tester.pumpWidget(_app(btn()));
      expect(material().color, MeowTokens.light.t1);
      expect(material().shape, const CircleBorder());
      expect(icon(), MeowTokens.light.bg);

      final mm = _glass(false);
      for (final host in [false, true]) {
        await tester.pumpWidget(_app(btn(), look: _glassLook, host: host));
        await tester.pumpAndSettle();   // 换主题有 200ms 的插值
        expect(find.byType(MeowGlassButton), findsNothing, reason: '静态的，不是逐颗的玻璃');
        expect(material().color, mm.buttonFill(MeowButtonFill.prominent));
        expect(material().shape, CircleBorder(side: mm.buttonSide));
        expect(icon(), mm.t1);
      }
    });

    testWidgets('分段（没要玻璃的）与选中的胶囊：玻璃下分段是中性的白滑块 + 墨色字、选中的胶囊是强调色的字；经典下都是墨色实心 + 页面底色的字', (tester) async {
      Widget row() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 300,
            child: MeowSegment<int>(items: const [(0, '白名单'), (1, '黑名单')], value: 0, onChanged: (_) {}),
          ),
          MePill(label: '系统应用', selected: true, onTap: () {}),
        ],
      );
      Color? segText() => tester
          .widget<AnimatedDefaultTextStyle>(find.ancestor(of: find.text('白名单'), matching: find.byType(AnimatedDefaultTextStyle)).first)
          .style
          .color;
      Color? pillText() => tester.widget<Text>(find.text('系统应用')).style!.color;

      await tester.pumpWidget(_app(row()));
      expect(segText(), MeowTokens.light.bg);
      expect(pillText(), MeowTokens.light.bg);
      expect(
        tester.widget<Material>(find.ancestor(of: find.text('系统应用'), matching: find.byType(Material)).first).color,
        MeowTokens.light.t1,
      );

      final mm = _glass(false);
      await tester.pumpWidget(_app(row(), look: _glassLook, host: true));
      await tester.pumpAndSettle();
      expect(find.byType(MeowGlassBox), findsNothing, reason: '没要玻璃的分段不加透镜');
      expect(segText(), mm.t1, reason: '分段同 iOS 的玻璃滑块：中性、墨色字');
      expect(mm.segmentThumb, Colors.white.withValues(alpha: 0.72));
      expect(MeowTokens.light.segmentThumb, MeowTokens.light.t1);
      expect(pillText(), mm.accent);
      final pill = tester.widget<Material>(find.ancestor(of: find.text('系统应用'), matching: find.byType(Material)).first);
      expect(pill.color, mm.buttonFill(MeowButtonFill.selected));
      expect(pill.shape, StadiumBorder(side: mm.buttonSide));
    });

    testWidgets('电源键：液态玻璃主题下没有墨色实心底，液面 55%、图标墨色；低端机（不画玻璃）垫静态半透明 + 细亮边；经典不变', (tester) async {
      final mm = _glass(false);
      Iterable<BoxDecoration> decos() => tester
          .widgetList<DecoratedBox>(find.descendant(of: find.byType(MeowPowerButton), matching: find.byType(DecoratedBox)))
          .map((d) => d.decoration)
          .whereType<BoxDecoration>();
      Color liquid() =>
          tester.widget<ColoredBox>(find.descendant(of: find.byType(MeowPowerButton), matching: find.byType(ColoredBox))).color;
      Color? icon() => tester.widget<MeowIcon>(find.byType(MeowIcon)).color;

      for (final on in [false, true]) {
        await tester.pumpWidget(_app(MeowPowerButton(on: on, onTap: () {}), look: _glassLook, host: true));
        await tester.pumpAndSettle();
        expect(find.byType(MeowGlassBox), findsOneWidget, reason: '玻璃透镜照旧');
        expect(decos().where((d) => d.color == mm.t1), isEmpty, reason: '没有墨色实心底（on: $on）');
        expect(find.byType(AnimatedContainer), findsNothing);
        expect(liquid(), mm.btnOn.withValues(alpha: mm.btnOn.a * 0.55));
        expect(icon(), mm.t1);
      }

      // 液态玻璃主题、没有玻璃宿主（低端机）
      await tester.pumpWidget(_app(MeowPowerButton(on: false, onTap: () {}), look: _glassLook));
      await tester.pumpAndSettle();
      expect(find.byType(MeowGlassBox), findsNothing);
      expect(decos().where((d) => d.color == mm.t1), isEmpty);
      expect(decos().where((d) => d.color == mm.buttonFill(MeowButtonFill.plain)), hasLength(1));
      expect(decos().where((d) => d.border == mm.buttonBorder), hasLength(1), reason: '细亮边描在液面上面');
      expect(liquid(), mm.btnOn.withValues(alpha: mm.btnOn.a * 0.55));
      expect(icon(), mm.t1);

      // 经典：墨色底 + 实色液面 + 页面底色的图标（连上后图标是 onBtn）
      await tester.pumpWidget(_app(MeowPowerButton(on: false, onTap: () {})));
      await tester.pumpAndSettle();
      final classic = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer)).decoration! as BoxDecoration;
      expect(classic.color, MeowTokens.light.t1);
      expect(liquid(), MeowTokens.light.btnOn);
      expect(icon(), MeowTokens.light.bg);
    });
  });
}
