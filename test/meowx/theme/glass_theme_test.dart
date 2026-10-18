import 'dart:convert';

import 'package:bett_box/meowx/glass/liquid_glass.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/theme/glass.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/morph_menu.dart';
import 'package:bett_box/meowx/theme/page_title.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _glassLook = MeowLook(style: MeowThemeStyle.glass);

/// 页面外面套上玻璃：[glass] = 宿主开着玻璃控件（液态玻璃主题），否则什么都不套（经典主题 / 没有宿主）。
Widget _app(Widget child, {bool glass = false, Brightness brightness = Brightness.light}) {
  final look = glass ? _glassLook : MeowLook.classic;
  // 同 App 里一样包在 Navigator 外面：从根 Navigator 弹出的菜单也在玻璃宿主里
  return MaterialApp(
    theme: meowThemeData(brightness: brightness, look: look),
    builder: glass
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
}

HSLColor _hsl(Color c) => HSLColor.fromColor(c);

void main() {
  group('卡片色推导', () {
    test('白：保持原来的两档；液态玻璃的深色换成更中性的一对', () {
      const white = Color(0xFFFFFFFF);
      expect(MeowTokens.cardShades(white, dark: false), (card: const Color(0xFFFFFFFF), card2: const Color(0xFFF3EDE6)));
      expect(MeowTokens.cardShades(white, dark: true), (card: const Color(0xFF221C29), card2: const Color(0xFF2F2838)));
      expect(
        MeowTokens.cardShades(white, dark: true, glass: true),
        (card: const Color(0xFF1C1A20), card2: const Color(0xFF2A2730)),
      );
      expect(MeowTokens.cardShades(white, dark: false, glass: true).card, const Color(0xFFFFFFFF));
    });

    test('浅色：直接用所选色，亮度低于 88% 的提到 88%；次级底同色相再深 5%', () {
      const cream = Color(0xFFFFF6EA);
      final light = MeowTokens.cardShades(cream, dark: false);
      expect(light.card, cream, reason: '本来就够亮：原样');
      expect(_hsl(light.card2).lightness, closeTo(_hsl(light.card).lightness - 0.05, 0.01));
      expect(_hsl(light.card2).hue, closeTo(_hsl(cream).hue, 1));

      const deep = Color(0xFF336699);
      final raised = MeowTokens.cardShades(deep, dark: false);
      expect(_hsl(raised.card).lightness, closeTo(0.88, 0.01));
      expect(_hsl(raised.card).hue, closeTo(_hsl(deep).hue, 1));
      expect(_hsl(raised.card).saturation, lessThanOrEqualTo(0.701));
    });

    test('深色：不直接用，取色相压成深色卡（饱和度 ≤ 28%、亮度 14%；次级底 ≤ 26% / 20%）', () {
      for (final c in const [Color(0xFFFFEFF4), Color(0xFFECF8F1), Color(0xFFFF0066), Color(0xFF336699)]) {
        final dark = MeowTokens.cardShades(c, dark: true);
        expect(_hsl(dark.card).lightness, closeTo(0.14, 0.01), reason: '$c');
        expect(_hsl(dark.card).saturation, lessThanOrEqualTo(0.285), reason: '$c');
        expect(_hsl(dark.card2).lightness, closeTo(0.20, 0.01), reason: '$c');
        expect(_hsl(dark.card2).saturation, lessThanOrEqualTo(0.265), reason: '$c');
        expect(_hsl(dark.card).hue, closeTo(_hsl(c).hue, 2), reason: '$c');
      }
    });

    test('缺省外观就是原来那两份 token（同一个实例）', () {
      expect(identical(MeowTokens.resolve(Brightness.light, MeowLook.classic), MeowTokens.light), isTrue);
      expect(identical(MeowTokens.resolve(Brightness.dark, MeowLook.classic), MeowTokens.dark), isTrue);
      expect(MeowTokens.light.glass, isFalse);
      expect(MeowTokens.light.heroGradient, isNull);
    });

    test('经典 + 别的卡片色：只换卡片两档，底色、樱粉主卡、电源键、选中态、强调色不变', () {
      const look = MeowLook(cardColor: 0xFFECF8F1);
      for (final b in Brightness.values) {
        final base = b == Brightness.dark ? MeowTokens.dark : MeowTokens.light;
        final t = MeowTokens.resolve(b, look);
        expect(t.bg, base.bg);
        expect(t.elev, isNot(base.elev));
        expect(t.elev, MeowTokens.cardShades(const Color(0xFFECF8F1), dark: b == Brightness.dark).card);
        expect(t.onHero, t.elev, reason: '经典主题下节点行就是卡片底');
        expect([t.hero, t.btnOn, t.soft, t.accent, t.t1, t.pink], [base.hero, base.btnOn, base.soft, base.accent, base.t1, base.pink]);
        expect(t.glass, isFalse);
        expect(t.heroGradient, isNull);
      }
    });

    test('液态玻璃：浅色底 #F5F1EC、深色纯黑；深色 + 白卡用 #1C1A20；主卡渐变、半透明白', () {
      final light = MeowTokens.resolve(Brightness.light, _glassLook);
      final dark = MeowTokens.resolve(Brightness.dark, _glassLook);
      expect(light.bg, const Color(0xFFF5F1EC));
      expect(dark.bg, const Color(0xFF000000));
      expect(dark.elev, const Color(0xFF1C1A20));
      expect(dark.card2, const Color(0xFF2A2730));
      expect(light.glass && dark.glass, isTrue);
      expect((light.heroGradient! as LinearGradient).colors, const [Color(0xFFFBDCE7), Color(0xFFF2BED2)]);
      expect((dark.heroGradient! as LinearGradient).colors, const [Color(0xFF5A2C47), Color(0xFF33202F)]);
      expect(light.onHero, const Color(0x9EFFFFFF));
      expect(dark.onHero, const Color(0x14FFFFFF));
      expect(light.glassPanel, const Color(0x8CFFFFFF));
      expect(light.glassTinted, isFalse);
      expect(
        MeowTokens.resolve(Brightness.light, const MeowLook(style: MeowThemeStyle.glass, glassTint: MeowGlassTint.tinted))
            .glassTinted,
        isTrue,
      );
    });

    test('外观取自设置：经典主题下玻璃样式不算数（切它不白建主题）', () {
      const s = MeowSettings(glassTint: MeowGlassTint.tinted, cardColor: 0xFFFFEFF4);
      expect(MeowLook.of(s), const MeowLook(cardColor: 0xFFFFEFF4));
      expect(MeowLook.of(s.copyWith(themeStyle: MeowThemeStyle.glass)).glassTint, MeowGlassTint.tinted);
      expect(MeowCardColors.nameOf(0xFFFFEFF4), '樱粉');
      expect(MeowCardColors.nameOf(0xFF123456), isNull);
    });

    test('MeowThemes：外观不变给同一对实例，换外观才重建', () {
      final themes = MeowThemes();
      final a = themes.of();
      expect(identical(themes.of(look: MeowLook.classic).light, a.light), isTrue);
      final g = themes.of(look: _glassLook);
      expect(identical(g.light, a.light), isFalse);
      expect(g.light.scaffoldBackgroundColor, const Color(0xFFF5F1EC));
      expect(identical(themes.of(look: const MeowLook(style: MeowThemeStyle.glass)).dark, g.dark), isTrue);
    });
  });

  group('启动卡片颜色 / 强调色', () {
    test('缺省樱粉 / 玫红：给回原来的值（渐变就是原来写死的那两组）', () {
      final l = MeowTokens.heroShades(const Color(MeowHeroColors.sakura), dark: false);
      final d = MeowTokens.heroShades(const Color(MeowHeroColors.sakura), dark: true);
      expect((l.hero, l.btnOn), (const Color(0xFFF7CDDB), const Color(0xFFE77FA6)));
      expect((d.hero, d.btnOn), (const Color(0xFF45283A), const Color(0xFFF3A6BF)));
      expect(l.gradient, const [Color(0xFFFBDCE7), Color(0xFFF2BED2)]);
      expect(d.gradient, const [Color(0xFF5A2C47), Color(0xFF33202F)]);
      final a = MeowTokens.accentShades(const Color(MeowAccentColors.rose), dark: false);
      expect((a.accent, a.soft, a.fill), (const Color(0xFFB02E63), const Color(0xFFFCE4EC), const Color(0xFFF3A6BF)));
      expect(MeowTokens.accentShades(const Color(MeowAccentColors.rose), dark: true).accent, const Color(0xFFF7B6CB));
    });

    test('用樱粉的算法推一遍：结果接近原来的写死值（推导规则与原设计一致）', () {
      // 樱粉本身走缺省分支；取一个只差一点点的颜色走推导分支，结果应与写死的值很接近
      const near = Color(0xFFF7CDDC);
      double dist(Color a, Color b) =>
          [(a.r - b.r).abs(), (a.g - b.g).abs(), (a.b - b.b).abs()].reduce((x, y) => x > y ? x : y);
      final l = MeowTokens.heroShades(near, dark: false);
      expect(dist(l.gradient[0], const Color(0xFFFBDCE7)), lessThan(0.04));
      expect(dist(l.gradient[1], const Color(0xFFF2BED2)), lessThan(0.04));
      expect(dist(l.btnOn, const Color(0xFFE77FA6)), lessThan(0.06));
      final d = MeowTokens.heroShades(near, dark: true);
      // 原来的深色几档色相偏紫一点（约 323°，樱粉是 340°），差在 5% 以内
      expect(dist(d.hero, const Color(0xFF45283A)), lessThan(0.05));
      expect(dist(d.gradient[0], const Color(0xFF5A2C47)), lessThan(0.05));
      expect(dist(d.gradient[1], const Color(0xFF33202F)), lessThan(0.05));
    });

    test('启动卡片：电源键跟着色相走（薄荷卡上不是粉按钮）；很深的自定义色提亮到墨色字读得清；深色压成深色', () {
      const mint = Color(0xFFCDEBDD);
      final l = MeowTokens.heroShades(mint, dark: false);
      expect(l.hero, mint);
      expect(_hsl(l.btnOn).hue, closeTo(_hsl(mint).hue, 1));
      expect(_hsl(l.btnOn).lightness, closeTo(0.70, 0.01));
      final d = MeowTokens.heroShades(mint, dark: true);
      expect(_hsl(d.hero).lightness, closeTo(0.21, 0.01));
      expect(_hsl(d.hero).saturation, lessThanOrEqualTo(0.275));

      const deep = Color(0xFF102040);
      final raised = MeowTokens.heroShades(deep, dark: false);
      expect(_hsl(raised.hero).lightness, greaterThanOrEqualTo(0.795));
      expect(MeowTokens.contrast(raised.hero, MeowTokens.light.t1), greaterThan(7));
    });

    test('强调色：浅色在页面底与白卡上都 ≥ 4.5:1（不够就压暗），深色在深底上 ≥ 4.5:1（提亮）；淡底同色相', () {
      for (final (_, c) in MeowAccentColors.presets) {
        final l = MeowTokens.accentShades(Color(c), dark: false);
        for (final bg in const [Color(0xFFEFE8DF), Color(0xFFF5F1EC), Color(0xFFFFFFFF)]) {
          expect(MeowTokens.contrast(l.accent, bg), greaterThanOrEqualTo(4.5), reason: '$c on $bg');
        }
        final d = MeowTokens.accentShades(Color(c), dark: true);
        for (final bg in const [Color(0xFF000000), Color(0xFF0E0C11), Color(0xFF221C29)]) {
          expect(MeowTokens.contrast(d.accent, bg), greaterThanOrEqualTo(4.5), reason: '$c on $bg');
        }
      }
      // 太亮的自定义强调色：浅色下被压暗到够用，色相不变
      const pale = Color(0xFF8FD3FF);
      final fixed = MeowTokens.accentShades(pale, dark: false).accent;
      expect(MeowTokens.contrast(pale, const Color(0xFFEFE8DF)), lessThan(4.5));
      expect(MeowTokens.contrast(fixed, const Color(0xFFEFE8DF)), greaterThanOrEqualTo(4.5));
      expect(_hsl(fixed).hue, closeTo(_hsl(pale).hue, 1));
      expect(_hsl(fixed).lightness, lessThan(_hsl(pale).lightness));
      // 淡底：浅色很淡的实色、深色半透明
      final blue = MeowTokens.accentShades(const Color(0xFF2F6FD0), dark: false);
      expect(blue.soft.a, 1);
      expect(_hsl(blue.soft).lightness, closeTo(0.94, 0.01));
      expect(MeowTokens.accentShades(const Color(0xFF2F6FD0), dark: true).soft.a, lessThan(0.3));
    });

    test('resolve：主卡 / 电源键跟启动卡片颜色，强调字 / 淡底 / 进度条跟强调色，语义色与墨色不变', () {
      const look = MeowLook(heroColor: 0xFFCDEBDD, accentColor: 0xFF2F6FD0);
      final t = MeowTokens.resolve(Brightness.light, look);
      final base = MeowTokens.light;
      expect(t.hero, const Color(0xFFCDEBDD));
      expect(t.btnOn, MeowTokens.heroShades(const Color(0xFFCDEBDD), dark: false).btnOn);
      expect(t.accent, MeowTokens.accentShades(const Color(0xFF2F6FD0), dark: false).accent);
      expect(t.fill, isNot(base.fill));
      expect([t.good, t.slow, t.t1, t.bg, t.elev], [base.good, base.slow, base.t1, base.bg, base.elev]);
      final glass = MeowTokens.resolve(Brightness.light, const MeowLook(style: MeowThemeStyle.glass, heroColor: 0xFFCDEBDD));
      expect((glass.heroGradient! as LinearGradient).colors, MeowTokens.heroShades(const Color(0xFFCDEBDD), dark: false).gradient);
    });
  });

  group('设置持久化', () {
    test('旧数据（没有这三项）：经典 + 透明 + 白卡', () {
      final old = MeowSettings.fromJson({'dnsMode': 'fake-ip', 'syncIntervalHours': 12});
      expect(old.themeStyle, MeowThemeStyle.classic);
      expect(old.glassTint, MeowGlassTint.clear);
      expect(old.cardColor, 0xFFFFFFFF);
      expect(old.heroColor, 0xFFF7CDDB);
      expect(old.accentColor, 0xFFB02E63);
      expect(MeowLook.of(old), MeowLook.classic);
      expect(old.syncIntervalHours, 12);
    });

    test('存了再读回来一样；认不出的值回到缺省', () {
      const s = MeowSettings(
        themeStyle: MeowThemeStyle.glass,
        glassTint: MeowGlassTint.tinted,
        cardColor: 0xFFEDF3FB,
        heroColor: 0xFFCDEBDD,
        accentColor: 0xFF2F6FD0,
      );
      final back = MeowSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect(back.themeStyle, MeowThemeStyle.glass);
      expect(back.glassTint, MeowGlassTint.tinted);
      expect(back.cardColor, 0xFFEDF3FB);
      expect(back.heroColor, 0xFFCDEBDD);
      expect(back.accentColor, 0xFF2F6FD0);
      final odd = MeowSettings.fromJson({'themeStyle': 'neon', 'glassTint': 'frosted'});
      expect(odd.themeStyle, MeowThemeStyle.classic);
      expect(odd.glassTint, MeowGlassTint.clear);
    });
  });

  group('控件：液态玻璃 / 经典', () {
    testWidgets('右上角圆钮与胶囊：玻璃下换成玻璃，实底主操作不变；经典下仍是实色、不多玻璃', (tester) async {
      Widget row() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RoundGlassButton(icon: Icons.refresh, tooltip: '刷新', onTap: () {}),
          RoundGlassButton(icon: Icons.bolt, filled: true, tooltip: '测速', onTap: () {}),
          MePill(label: '高级设置', onTap: () {}),
        ],
      );
      await tester.pumpWidget(_app(row()));
      expect(find.byType(LiquidGlass), findsNothing);
      expect(find.byType(MeowGlassButton), findsNothing);

      await tester.pumpWidget(_app(row(), glass: true));
      await tester.pump();
      expect(find.byType(MeowGlassButton), findsNWidgets(2), reason: '刷新圆钮 + 高级设置胶囊');
      expect(
        find.ancestor(of: find.byIcon(Icons.bolt), matching: find.byType(MeowGlassButton)),
        findsNothing,
        reason: '实底的主操作仍是墨色实心块',
      );
      expect(find.byType(LiquidGlass), findsNWidgets(2));
    });

    testWidgets('玻璃圆钮：点得到，不可用时不响应', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(RoundGlassButton(icon: Icons.refresh, tooltip: '刷新', onTap: () => taps++), glass: true));
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(taps, 1);
      await tester.pumpWidget(
        _app(RoundGlassButton(icon: Icons.refresh, tooltip: '刷新', busy: true, onTap: () => taps++), glass: true),
      );
      await tester.tap(find.byType(MeowGlassButton));
      await tester.pump(const Duration(milliseconds: 300));
      expect(taps, 1);
    });

    testWidgets('首页模式分段：玻璃下选中块是玻璃透镜，经典下仍是实心滑块；没要玻璃的分段两种主题都不变', (tester) async {
      Widget seg({bool glass = true}) => SizedBox(
        width: 300,
        child: MeowSegment<int>(items: const [(0, '规则'), (1, '全局'), (2, '直连')], value: 0, glass: glass, onChanged: (_) {}),
      );
      await tester.pumpWidget(_app(seg()));
      expect(find.byType(MeowGlassBox), findsNothing);
      await tester.pumpWidget(_app(seg(), glass: true));
      expect(find.byType(MeowGlassBox), findsOneWidget);
      await tester.pumpWidget(_app(seg(glass: false), glass: true));
      expect(find.byType(MeowGlassBox), findsNothing);
    });

    testWidgets('电源键：玻璃下盖一块玻璃（圆角方块，不是正圆），经典下没有', (tester) async {
      Widget power() => MeowPowerButton(on: true, onTap: () {});
      await tester.pumpWidget(_app(power()));
      expect(find.byType(MeowGlassBox), findsNothing);
      await tester.pumpWidget(_app(power(), glass: true));
      await tester.pumpAndSettle();
      final box = tester.widget<MeowGlassBox>(find.byType(MeowGlassBox));
      expect(box.radius, BorderRadius.circular(80 * 0.325));
      expect(box.style.tint.a, lessThan(0.2), reason: '几乎不着色：颜色来自背后的墨色底与液面');
    });

    testWidgets('弹出菜单：玻璃下面板是一块玻璃（菜单那一档），经典下是实色', (tester) async {
      Widget menu() => MeowMenuButton<int>(
        entries: () => const [MeowMenuItem(0, '列表', checked: true), MeowMenuItem(1, '单组')],
        onSelected: (_) {},
        builder: (_, open) => RoundGlassButton(icon: Icons.grid_view_rounded, tooltip: '视图', onTap: open),
      );
      await tester.pumpWidget(_app(menu()));
      await tester.tap(find.byIcon(Icons.grid_view_rounded));
      await tester.pumpAndSettle();
      expect(find.text('单组'), findsOneWidget);
      expect(find.byType(MeowGlassBox), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_app(menu(), glass: true));
      expect(find.byType(LiquidGlassFade), findsOneWidget, reason: '玻璃触发钮用 LiquidGlassFade 淡出');
      await tester.tap(find.byIcon(Icons.grid_view_rounded));
      await tester.pumpAndSettle();
      final panel = tester.widget<MeowGlassBox>(find.byType(MeowGlassBox));
      expect(panel.rim, isNotNull);
      expect(panel.radius.topLeft.x, closeTo(16, 0.01));
      await tester.tap(find.text('单组'));
      await tester.pumpAndSettle();
      expect(find.text('单组'), findsNothing);
    });
  });
}
