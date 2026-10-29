import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bett_box/meowx/glass/liquid_glass.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/app/backdrop_host.dart';
import 'package:bett_box/meowx/theme/backdrop.dart';
import 'package:bett_box/meowx/theme/card_surface.dart';
import 'package:bett_box/meowx/theme/glass.dart';
import 'package:bett_box/meowx/theme/glass_art.dart';
import 'package:bett_box/meowx/theme/glass_card.dart';
import 'package:bett_box/meowx/theme/meow_theme.dart';
import 'package:bett_box/meowx/theme/morph_menu.dart';
import 'package:bett_box/meowx/theme/page_background.dart';
import 'package:bett_box/meowx/theme/page_title.dart';
import 'package:bett_box/meowx/theme/tokens.dart';
import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    test('白：保持原来的两档', () {
      const white = Color(0xFFFFFFFF);
      expect(MeowTokens.cardShades(white, dark: false), (card: const Color(0xFFFFFFFF), card2: const Color(0xFFF3EDE6)));
      expect(MeowTokens.cardShades(white, dark: true), (card: const Color(0xFF221C29), card2: const Color(0xFF2F2838)));
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

    test('液态玻璃 + 白 + 平涂背景：浅色底 #F5F1EC、深色纯黑；卡片底是磨砂填充的中间值；主卡渐变、半透明白', () {
      const flat = MeowLook(style: MeowThemeStyle.glass, bgPattern: MeowBgPattern.flat);
      final light = MeowTokens.resolve(Brightness.light, flat);
      final dark = MeowTokens.resolve(Brightness.dark, flat);
      expect(light.bg, const Color(0xFFF5F1EC));
      expect(dark.bg, const Color(0xFF000000));
      expect(light.backdrop!.pattern, MeowBgPattern.flat);
      // 磨砂 0.5：浅色填充 白 .56 → .34，深色 .16 → .07；elev 取中间
      expect(light.elev.a, closeTo(0.45, 0.01));
      expect(dark.elev.a, closeTo(0.115, 0.01));
      expect(light.card2, Colors.white.withValues(alpha: 0.38));
      expect(dark.card2, Colors.white.withValues(alpha: 0.07));
      expect(light.elevSolid, Color.alphaBlend(light.elev, const Color(0xFFF5F1EC)));
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
      expect(g.light.scaffoldBackgroundColor, MeowTokens.resolve(Brightness.light, _glassLook).bg);
      expect(identical(themes.of(look: const MeowLook(style: MeowThemeStyle.glass)).dark, g.dark), isTrue);
    });
  });

  group('液态玻璃：底色 + 玻璃卡片', () {
    test('浅色底色：同色相、饱和度 ≤ 0.6、亮度 0.925 → 0.885 自上而下；中间色当 bg', () {
      for (final (name, c) in MeowCardColors.presets.skip(1)) {
        final g = MeowTokens.glassShades(Color(c), dark: false);
        final top = _hsl(g.gradient![0]), bottom = _hsl(g.gradient![1]);
        expect(top.lightness, closeTo(0.925, 0.006), reason: name);
        expect(bottom.lightness, closeTo(0.885, 0.006), reason: name);
        expect(top.saturation, lessThanOrEqualTo(0.605), reason: name);
        expect(top.hue, closeTo(_hsl(Color(c)).hue, 3), reason: name);
        expect(_hsl(g.bg).lightness, closeTo(0.905, 0.006), reason: name);
      }
      // 饱和度低于 0.6 的保持原值
      const grey = Color(0xFFE6E0F0);
      expect(_hsl(MeowTokens.glassShades(grey, dark: false).gradient![0]).saturation, closeTo(_hsl(grey).saturation, 0.03));
    });

    test('深色底色：同色相、饱和度 ≤ 0.32、亮度 0.12 → 0.07；白 → 纯黑', () {
      for (final (name, c) in MeowCardColors.presets.skip(1)) {
        final g = MeowTokens.glassShades(Color(c), dark: true);
        expect(_hsl(g.gradient![0]).lightness, closeTo(0.12, 0.006), reason: name);
        expect(_hsl(g.gradient![1]).lightness, closeTo(0.07, 0.006), reason: name);
        expect(_hsl(g.gradient![0]).saturation, lessThanOrEqualTo(0.325), reason: name);
        expect(_hsl(g.gradient![0]).hue, closeTo(_hsl(Color(c)).hue, 3), reason: name);
      }
      final white = MeowTokens.glassShades(const Color(MeowCardColors.white), dark: true);
      expect((white.bg, white.gradient), (const Color(0xFF000000), null));
    });

    test('卡片：浅 = 白 52% + 白 75% 亮边 + 白 90% 高光 + 很淡的同色相投影；深 = 白 7% / 12% / 10%、不投影', () {
      const mint = Color(0xFFECF8F1);
      final l = MeowTokens.glassShades(mint, dark: false);
      expect((l.card, l.card2, l.rim, l.sheen), (
        const Color(0x85FFFFFF),
        const Color(0x8CFFFFFF),
        const Color(0xBFFFFFFF),
        const Color(0xE6FFFFFF),
      ));
      expect(l.shadow.a, closeTo(0.10, 0.01));
      expect(_hsl(l.shadow).hue, closeTo(_hsl(mint).hue, 3));
      final d = MeowTokens.glassShades(mint, dark: true);
      expect((d.card, d.card2, d.rim, d.sheen, d.shadow), (
        const Color(0x12FFFFFF),
        const Color(0x0FFFFFFF),
        const Color(0x1FFFFFFF),
        const Color(0x1AFFFFFF),
        const Color(0x00000000),
      ));
    });

    test('着色：浅色卡片 = 所选色相的极浅色 62%，深色 = 同色相 12%；白 = 白 62% / 12%', () {
      const blue = Color(0xFFEDF3FB);
      final l = MeowTokens.glassShades(blue, dark: false, tinted: true).card;
      expect(l.a, closeTo(0.62, 0.01));
      expect(_hsl(l.withValues(alpha: 1)).lightness, closeTo(0.97, 0.01));
      expect(_hsl(l.withValues(alpha: 1)).hue, closeTo(_hsl(blue).hue, 3));
      final d = MeowTokens.glassShades(blue, dark: true, tinted: true).card;
      expect(d.a, closeTo(0.12, 0.01));
      expect(_hsl(d.withValues(alpha: 1)).hue, closeTo(_hsl(blue).hue, 3));
      expect(MeowTokens.glassShades(const Color(MeowCardColors.white), dark: false, tinted: true).card, const Color(0x9EFFFFFF));
      expect(MeowTokens.glassShades(const Color(MeowCardColors.white), dark: true, tinted: true).card, const Color(0x1FFFFFFF));
    });

    test('resolve：旧配置的 cardColor 在玻璃主题下当底色；浮层用叠好的实色；经典主题没有背景与磨砂', () {
      const look = MeowLook(style: MeowThemeStyle.glass, cardColor: 0xFFFFEFF4, bgPattern: MeowBgPattern.flat);
      final t = MeowTokens.resolve(Brightness.light, look);
      final g = MeowTokens.glassShades(const Color(0xFFFFEFF4), dark: false);
      expect(t.bgGradient, g.gradient);
      expect(t.elevSolid.a, 1);
      expect(meowThemeData(brightness: Brightness.light, look: look).dialogTheme.backgroundColor, t.elevSolid);
      expect(meowThemeData(brightness: Brightness.light, look: look).colorScheme.surfaceContainerHighest.a, 1);

      final classic = MeowTokens.resolve(Brightness.light, const MeowLook(cardColor: 0xFFFFEFF4));
      expect(classic.backdrop, isNull);
      expect(classic.cardRim, isNull);
      expect(classic.bgGradient, isNull);
      expect(classic.elevSolid, classic.elev);
      expect(MeowTokens.light.backdrop, isNull);
      expect(classic.card(BorderRadius.circular(24)), BoxDecoration(color: classic.elev, borderRadius: BorderRadius.circular(24)));
    });

  });

  group('液态玻璃：渐变底色', () {
    test('预设：两端各取自己的色相；浅色饱和度 ≤ 0.6、亮度 0.915 → 0.885，深色饱和度 ≤ 0.35、亮度 0.13 → 0.075；斜向', () {
      for (final (name, a, b) in MeowBgGradients.presets) {
        for (final dark in [false, true]) {
          final g = MeowTokens.glassGradientShades(Color(a), Color(b), dark: dark);
          expect(g.diagonal, isTrue, reason: name);
          final from = _hsl(g.gradient![0]), to = _hsl(g.gradient![1]);
          expect(from.lightness, closeTo(dark ? 0.13 : 0.915, 0.006), reason: '$name $dark');
          expect(to.lightness, closeTo(dark ? 0.075 : 0.885, 0.006), reason: '$name $dark');
          // 深色亮度很低，8 位量化后饱和度会偏出零点几
          expect(from.saturation, lessThanOrEqualTo(dark ? 0.40 : 0.605), reason: '$name $dark');
          expect(to.saturation, lessThanOrEqualTo(dark ? 0.40 : 0.605), reason: '$name $dark');
          expect(from.hue, closeTo(_hsl(Color(a)).hue, 4), reason: '$name $dark');
          expect(to.hue, closeTo(_hsl(Color(b)).hue, 4), reason: '$name $dark');
          expect(g.bg, Color.lerp(g.gradient![0], g.gradient![1], 0.5));
        }
      }
      expect(MeowBgGradients.nameOf(MeowBgGradients.defaultFrom, MeowBgGradients.defaultTo), '樱粉 · 薰衣草');
      expect(MeowBgGradients.nameOf(0xFF123456, 0xFF654321), isNull);
    });

    test('resolve：选了渐变 + 平涂背景就铺斜向渐变；单色平涂是自上而下', () {
      const look = MeowLook(
        style: MeowThemeStyle.glass,
        bgStyle: MeowBgStyle.gradient,
        gradientFrom: 0xFFCDEBDD,
        gradientTo: 0xFFCFDDF3,
        bgPattern: MeowBgPattern.flat,
      );
      final t = MeowTokens.resolve(Brightness.light, look);
      final g = MeowTokens.glassGradientShades(const Color(0xFFCDEBDD), const Color(0xFFCFDDF3), dark: false);
      expect(t.bgGradient, g.gradient);
      expect(t.bgDiagonal, isTrue);
      final solid = MeowTokens.resolve(
        Brightness.light,
        const MeowLook(style: MeowThemeStyle.glass, cardColor: 0xFFECF8F1, bgPattern: MeowBgPattern.flat),
      );
      expect(solid.bgDiagonal, isFalse);
      // 着色：底色渐变本身的着色卡片取值照旧（给自定义取色页的预览用）
      final tinted = MeowTokens.glassGradientShades(const Color(0xFFCDEBDD), const Color(0xFFCFDDF3), dark: false, tinted: true);
      expect(tinted.card.a, closeTo(0.62, 0.01));
    });

    test('设置：老配置没有渐变几项 = 单色；存了再读回来一样；经典 / 单色时外观不带渐变两色（切它不白建主题）', () {
      final old = MeowSettings.fromJson({'themeStyle': 'glass', 'cardColor': 0xFFFFF6EA});
      expect(old.bgStyle, MeowBgStyle.solid);
      expect(MeowLook.of(old).bgStyle, MeowBgStyle.solid);
      expect(MeowLook.of(old).bgPattern, MeowBgPattern.blobs, reason: '老配置没有背景这一项 = 光斑');
      expect(MeowLook.of(old).glassFrost, 0.5);
      const s = MeowSettings(themeStyle: MeowThemeStyle.glass, bgStyle: MeowBgStyle.gradient, bgGradientFrom: 0xFF112233, bgGradientTo: 0xFF445566);
      final back = MeowSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect((back.bgStyle, back.bgGradientFrom, back.bgGradientTo), (MeowBgStyle.gradient, 0xFF112233, 0xFF445566));
      expect(MeowSettings.fromJson({'bgStyle': 'rainbow'}).bgStyle, MeowBgStyle.solid);
      expect(MeowLook.of(s.copyWith(themeStyle: MeowThemeStyle.classic)), MeowLook.classic);
      expect(MeowLook.of(s.copyWith(bgStyle: MeowBgStyle.solid)), MeowLook.of(const MeowSettings(themeStyle: MeowThemeStyle.glass)));
    });

    testWidgets('整屏渐变：小块（展开代理组的盖层、平移中的页面）按屏幕位置取色，与整屏底拼得上', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const fill = MeowBgFill(Color(0xFF808080), [Color(0xFF000000), Color(0xFFFFFFFF)], Size(400, 800), diagonal: true);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: Stack(
            textDirection: TextDirection.ltr,
            children: [
              const Positioned.fill(child: MeowBgBox(fill: fill)),
              const Positioned(left: 100, top: 300, width: 80, height: 60, child: MeowBgBox(fill: fill)),
              // 往右平移 120 的一块（Tab 平推中的页面）
              Positioned(
                left: 0,
                top: 500,
                width: 200,
                height: 100,
                child: Transform.translate(offset: const Offset(120, 0), child: const MeowBgBox(fill: fill)),
              ),
            ],
          ),
        ),
      );
      final image = await tester.runAsync(
        () => (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(),
      );
      final bytes = (await tester.runAsync(() => image!.toByteData()))!;
      int px(int x, int y) => bytes.getUint8((y * 400 + x) * 4);
      for (final (inside, outside) in const [
        ((178, 330), (182, 330)), // 小块右边缘内外
        ((140, 301), (140, 298)), // 小块上边缘内外
        ((318, 550), (322, 550)), // 平移块右边缘内外
      ]) {
        expect((px(inside.$1, inside.$2) - px(outside.$1, outside.$2)).abs(), lessThanOrEqualTo(3), reason: '$inside / $outside');
      }
      // 确实是斜向：左上暗、右下亮
      expect(px(5, 5), lessThan(px(390, 790)));
      expect(px(390, 5), greaterThan(px(5, 5)));
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

  group('内容卡片与页面底', () {
    Widget themed(Widget child, MeowLook look) => MaterialApp(
      theme: meowThemeData(brightness: Brightness.light, look: look),
      home: Scaffold(body: Center(child: child)),
    );
    const mint = MeowLook(style: MeowThemeStyle.glass, cardColor: 0xFFECF8F1);

    testWidgets('MeowCardMaterial：经典主题原样是实色 Material；玻璃主题是磨砂玻璃底 + 透明 Material（水波照旧）', (tester) async {
      var taps = 0;
      Widget card() => MeowCardMaterial(
        borderRadius: BorderRadius.circular(18),
        child: InkWell(onTap: () => taps++, child: const SizedBox(width: 120, height: 60)),
      );
      await tester.pumpWidget(themed(card(), MeowLook.classic));
      final m = tester.widget<Material>(find.descendant(of: find.byType(MeowCardMaterial), matching: find.byType(Material)));
      expect(m.color, MeowTokens.light.elev);
      expect(find.byType(MeowFrostBox), findsNothing);

      await tester.pumpWidget(themed(card(), mint));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(MeowCardMaterial), matching: find.byType(MeowFrostBox)), findsOneWidget);
      final inner = tester.widget<Material>(find.descendant(of: find.byType(MeowCardMaterial), matching: find.byType(Material)));
      expect(inner.type, MaterialType.transparency);
      await tester.tap(find.byType(InkWell));
      expect(taps, 1);
    });

    testWidgets('GlassCard / MeowCard：玻璃主题下是磨砂玻璃卡片，经典下是原来的实色 Container', (tester) async {
      Widget cards() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GlassCard(child: SizedBox(width: 100, height: 40)),
          MeowCard(radius: BorderRadius.circular(20), padding: const EdgeInsets.all(8), child: const SizedBox(width: 100, height: 40)),
        ],
      );
      await tester.pumpWidget(themed(cards(), MeowLook.classic));
      expect(find.byType(MeowFrostBox), findsNothing);
      final deco = tester.widget<Container>(find.descendant(of: find.byType(MeowCard), matching: find.byType(Container))).decoration;
      expect(deco, BoxDecoration(color: MeowTokens.light.elev, borderRadius: BorderRadius.circular(20)));
      await tester.pumpWidget(themed(cards(), mint));
      await tester.pumpAndSettle();
      expect(find.byType(MeowFrostBox), findsNWidgets(2));
    });

    testWidgets('页面底：玻璃平涂 + 底色 = 按整屏铺的渐层，经典 / 白 = 平涂；切换时子树不重建', (tester) async {
      final key = GlobalKey();
      Widget page(MeowLook look) => MaterialApp(
        theme: meowThemeData(brightness: Brightness.light, look: look),
        home: MeowPageBackground(child: SizedBox.expand(key: key)),
      );
      await tester.pumpWidget(page(MeowLook.classic));
      final state = key.currentContext;
      MeowBgFill fill() => tester.widget<MeowBgBox>(find.byType(MeowBgBox)).fill;
      expect(fill().flat, isTrue);
      expect(fill().color, MeowTokens.light.bg);
      const mintFlat = MeowLook(style: MeowThemeStyle.glass, cardColor: 0xFFECF8F1, bgPattern: MeowBgPattern.flat);
      await tester.pumpWidget(page(mintFlat));
      await tester.pumpAndSettle();
      expect(fill().flat, isFalse);
      expect(fill().gradient, MeowTokens.glassShades(const Color(0xFFECF8F1), dark: false).gradient);
      expect(fill().size, tester.view.physicalSize / tester.view.devicePixelRatio);
      expect(key.currentContext, same(state), reason: '同一种 widget，换底色不拆子树');
      // 光斑背景：没有宿主渲染背景图时先画底色的斜向渐变
      await tester.pumpWidget(page(mint));
      await tester.pumpAndSettle();
      expect(fill().diagonal, isTrue);
      expect(fill().images, isNull);
    });
  });

  group('液态玻璃：背景（平涂 / 光斑 / 插画）与磨砂卡片', () {
    final looks = [
      for (final (_, c) in MeowCardColors.presets) MeowLook(style: MeowThemeStyle.glass, cardColor: c),
      for (final (_, a, b) in MeowBgGradients.presets)
        MeowLook(style: MeowThemeStyle.glass, bgStyle: MeowBgStyle.gradient, gradientFrom: a, gradientTo: b),
    ];
    MeowLook with2(MeowLook l, {MeowBgPattern? pattern, double? frost, int? accent}) => MeowLook(
      style: l.style,
      cardColor: l.cardColor,
      bgStyle: l.bgStyle,
      gradientFrom: l.gradientFrom,
      gradientTo: l.gradientTo,
      bgPattern: pattern ?? l.bgPattern,
      glassFrost: frost ?? l.glassFrost,
      accentColor: accent ?? l.accentColor,
    );

    test('磨砂强度 ≥ 0.5：浅色填充 (0.24+0.36f+0.14) → (0.24+0.36f−0.08)、模糊 14+30f、饱和 1.8；深色 (0.10+0.12f) → (0.04+0.06f)、饱和 1.6', () {
      for (final f in const [0.5, 0.75, 1.0]) {
        final l = MeowBackdrop.of(MeowLook(style: MeowThemeStyle.glass, glassFrost: f), dark: false);
        expect(l.fill.top, closeTo(0.38 + 0.36 * f, 1e-9));
        expect(l.fill.bottom, closeTo(0.16 + 0.36 * f, 1e-9));
        expect(l.blurSigma, 14 + 30 * f);
        expect(l.saturation, 1.8);
        final d = MeowBackdrop.of(MeowLook(style: MeowThemeStyle.glass, glassFrost: f), dark: true);
        expect(d.fill.top, closeTo(0.10 + 0.12 * f, 1e-9));
        expect(d.fill.bottom, closeTo(0.04 + 0.06 * f, 1e-9));
        expect(d.saturation, 1.6);
      }
    });

    test('磨砂强度 < 0.5 往透明走：0 = 浅 (0.08, 0.02) / 深 (0.03, 0)、模糊 1、不提饱和、没有罩色、不垫；0.25 在两端正中', () {
      MeowBackdrop at(double f, bool dark) =>
          MeowBackdrop.of(MeowLook(style: MeowThemeStyle.glass, bgPattern: MeowBgPattern.art, glassFrost: f), dark: dark);
      final l0 = at(0, false), d0 = at(0, true);
      expect(l0.fill.top, closeTo(0.08, 1e-9));
      expect(l0.fill.bottom, closeTo(0.02, 1e-9));
      expect(d0.fill.top, closeTo(0.03, 1e-9));
      expect(d0.fill.bottom, closeTo(0, 1e-9));
      expect((l0.blurSigma, l0.saturation, d0.saturation), (1, 1, 1));
      expect([...l0.veil, ...d0.veil].every((c) => c.a == 0), isTrue);
      expect(l0.scrim(const Color(0xFF2A2130)), 0);
      expect(d0.scrim(const Color(0xFFF7F0F3)), 0);
      final l = at(0.25, false), hi = at(0.5, false);
      expect(l.fill.top, closeTo((0.08 + hi.fill.top) / 2, 1e-9));
      expect(l.fill.bottom, closeTo((0.02 + hi.fill.bottom) / 2, 1e-9));
      expect(l.blurSigma, closeTo(15, 1e-9));
      expect(l.saturation, closeTo(1.4, 1e-9));
      expect(l.veil[0].a, closeTo(0.35 / 2, 0.01));
      expect(at(0.25, true).veil[1].a, closeTo(0.60 / 2, 0.01));
      // 0.5 起与第一版一样
      expect(hi.blurSigma, 29);
      expect(hi.veil[0].a, closeTo(0.35, 0.01));
    });

    test('卡片取样图分辨率跟着模糊：模糊 ≥ 8dp 每 dp 1/4 像素，磨砂 0（模糊 1dp）每 dp 2 像素、不超过像素比；清晰图插画按像素比、光斑半个像素；一张不超过像素上限', () {
      expect(MeowBackdrop.frostScaleFor(29, 2.75), 0.25);
      expect(MeowBackdrop.frostScaleFor(44, 2.75), 0.25);
      expect(MeowBackdrop.frostScaleFor(4, 2.75), 0.5);
      expect(MeowBackdrop.frostScaleFor(1, 2.75), 2);
      expect(MeowBackdrop.frostScaleFor(1, 1.25), 1.25);
      expect(MeowBackdropHost.sharpScaleFor(MeowBgPattern.art, 2.75), 2.75);
      expect(MeowBackdropHost.sharpScaleFor(MeowBgPattern.blobs, 2.75), 0.5);
      // 手机整屏按像素比不降；4K 桌面窗口整窗降到像素上限以内
      const phone = Size(393, 873), desk = Size(2560, 1440);
      expect(MeowBackdropHost.capped(2.75, phone), 2.75);
      final k = MeowBackdropHost.capped(1.5, desk);
      expect(desk.width * k * desk.height * k, lessThanOrEqualTo(MeowBackdropHost.pixelBudget + 1));
    });

    test('自己的图片：按 cover 铺满需要的大小解码（大图缩小解码，小图不放大）；读不了的数据返回 null', () async {
      Future<Uint8List> png(int w, int h) async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF336699));
        final image = await recorder.endRecording().toImage(w, h);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      }

      final big = await MeowGlassArt.decode(await png(400, 300), const Size(100, 100));
      expect((big!.width, big.height), (133, 100));
      big.dispose();
      final small = await MeowGlassArt.decode(await png(40, 30), const Size(100, 100));
      expect((small!.width, small.height), (40, 30));
      small.dispose();
      expect(await MeowGlassArt.decode(Uint8List.fromList([1, 2, 3, 4]), const Size(10, 10)), isNull);
    });

    test('选中态的底：经典 = 淡底叠卡片底；玻璃 0.5 起同经典口径，磨砂 0 淡到 0.25 / 0.7', () {
      final classic = MeowTokens.resolve(Brightness.light, MeowLook.classic);
      expect(classic.selectedCard, Color.alphaBlend(classic.soft, classic.elev));
      MeowTokens glass(double f) =>
          MeowTokens.resolve(Brightness.light, MeowLook(style: MeowThemeStyle.glass, glassFrost: f, accentColor: 0xFF2E7DB0));
      final g5 = glass(0.5), g0 = glass(0);
      expect(g5.selectedCard, Color.alphaBlend(g5.soft, g5.elev));
      expect(g0.selectedCard, Color.alphaBlend(g0.soft.withValues(alpha: g0.soft.a * 0.25 / 0.7), g0.elev));
    });

    test('颜色来源：渐变用两端；单色第二色 = 同色相 +28°；光斑四团的位置、大小、颜色按 340 宽等比', () {
      final g = MeowBackdrop.of(
        const MeowLook(style: MeowThemeStyle.glass, bgStyle: MeowBgStyle.gradient, gradientFrom: 0xFFCDEBDD, gradientTo: 0xFFCFDDF3),
        dark: false,
      );
      expect(g.hueA, closeTo(_hsl(const Color(0xFFCDEBDD)).hue, 0.01));
      expect(g.hueB, closeTo(_hsl(const Color(0xFFCFDDF3)).hue, 0.01));
      final s = MeowBackdrop.of(const MeowLook(style: MeowThemeStyle.glass, cardColor: 0xFFFFEFF4), dark: false);
      expect(s.hueB, closeTo((s.hueA + 28) % 360, 0.01));
      expect(s.diagonal, isTrue);
      // 340 × 720 的手机上就是设计稿的数
      final blobs = s.blobs(const Size(340, 720));
      expect(blobs.map((b) => (b.center, b.radius)).toList(), const [
        (Offset(50, 180), 120.0),
        (Offset(300, 390), 130.0),
        (Offset(120, 580), 100.0),
        (Offset(280, 50), 80.0),
      ]);
      expect(_hsl(blobs[0].color).lightness, closeTo(0.78, 0.01));
      expect(_hsl(blobs[0].color).saturation, closeTo(0.75, 0.01));
      expect(blobs[0].color.a, closeTo(0.9, 0.01));
      expect(_hsl(blobs[2].color).hue, closeTo(340, 0.5));
      expect(blobs[2].color.a, closeTo(0.72, 0.01));
      expect(blobs[3].color.a, closeTo(0.63, 0.01));
      final dark = MeowBackdrop.of(const MeowLook(style: MeowThemeStyle.glass, cardColor: 0xFFFFEFF4), dark: true).blobs(const Size(340, 720));
      expect(_hsl(dark[1].color).lightness, closeTo(0.28, 0.01));
      expect(dark[0].color.a, closeTo(0.75, 0.01));
      // 宽屏按高度比例，不按宽度放大
      expect(MeowBackdrop.scaleOf(const Size(1280, 720)), 1.0);
    });

    test('插画那层底色：浅 (h,0.5,0.92) α.35 → (h,0.5,0.88) α.45；深 (h,0.5,0.12) α.55 → (h,0.5,0.07) α.60', () {
      final l = MeowBackdrop.of(const MeowLook(style: MeowThemeStyle.glass, bgPattern: MeowBgPattern.art), dark: false).veil;
      expect(l[0].a, closeTo(0.35, 0.01));
      expect(l[1].a, closeTo(0.45, 0.01));
      expect(_hsl(l[0].withValues(alpha: 1)).lightness, closeTo(0.92, 0.01));
      expect(_hsl(l[1].withValues(alpha: 1)).lightness, closeTo(0.88, 0.01));
      final d = MeowBackdrop.of(const MeowLook(style: MeowThemeStyle.glass, bgPattern: MeowBgPattern.art), dark: true).veil;
      expect(d[0].a, closeTo(0.55, 0.01));
      expect(d[1].a, closeTo(0.60, 0.01));
      expect(MeowBackdrop.coverRect(const Size(900, 900), const Size(340, 720)).height, closeTo(720 * 1.12, 0.01));
    });

    test('卡片对比度：全部底色预设 × 浅 / 深 × 三种背景 × 磨砂 0 / 0.5 / 1 × 全部强调色——最不利的背景 + 统一垫层 + 填充上正文 ≥ 7、次级字与强调色 ≥ 4.5', () {
      for (final b in Brightness.values) {
        final dark = b == Brightness.dark;
        for (final base in looks) {
          for (final pattern in MeowBgPattern.values) {
            for (final f in const [0.5, 1.0]) {
              for (final (_, accent) in MeowAccentColors.presets) {
                final t = MeowTokens.resolve(b, with2(base, pattern: pattern, frost: f, accent: accent));
                final spec = t.backdrop!;
                final scrim = t.backdropScrim;
                expect(scrim, spec.scrim(t.t1));
                // 垫层与填充合起来不超过 0.85（浅色是白的总覆盖率，深色是黑垫层本身）
                if (dark) {
                  expect(scrim, lessThanOrEqualTo(0.85 + 1e-9));
                } else {
                  expect(1 - (1 - scrim) * (1 - spec.fill.bottom), lessThanOrEqualTo(math.max(0.85, spec.fill.bottom) + 1e-9));
                }
                for (final worst in spec.worstBackgrounds()) {
                  final surface = spec.cardSurface(worst, scrim);
                  final why = '$b ${base.bgStyle} ${base.cardColor.toRadixString(16)} $pattern f=$f accent=$accent worst=$worst';
                  expect(MeowTokens.contrast(t.t1, surface), greaterThanOrEqualTo(7), reason: why);
                  expect(MeowTokens.contrast(t.t2, surface), greaterThanOrEqualTo(4.5), reason: why);
                  expect(MeowTokens.contrast(t.accent, surface), greaterThanOrEqualTo(4.5), reason: why);
                }
              }
            }
          }
        }
      }
    });

    test('光斑④取两色相的圆周平均：跨 0° 不偏到对面（蜜桃 · 樱粉不出青色）', () {
      expect(MeowBackdrop.meanHue(350, 10), anyOf(closeTo(0, 1e-6), closeTo(360, 1e-6)));
      expect(MeowBackdrop.meanHue(100, 200), closeTo(150, 1e-6));
      final s = MeowBackdrop.of(
        const MeowLook(style: MeowThemeStyle.glass, bgStyle: MeowBgStyle.gradient, gradientFrom: 0xFFFBD3C7, gradientTo: 0xFFF7CDDB),
        dark: false,
      );
      final h = _hsl(s.blobs(const Size(340, 720))[3].color).hue;
      expect(h < 40 || h > 320, isTrue, reason: '$h');
    });

    test('直接写在背景上的字（平涂 / 光斑）：次级字 ≥ 4.5；深色正文 ≥ 4.5', () {
      for (final b in Brightness.values) {
        for (final base in looks) {
          for (final pattern in const [MeowBgPattern.flat, MeowBgPattern.blobs]) {
            final t = MeowTokens.resolve(b, with2(base, pattern: pattern));
            for (final bg in t.backdrop!.worstBackgrounds(saturated: false)) {
              expect(MeowTokens.contrast(t.t2, bg), greaterThanOrEqualTo(4.5), reason: '$b $pattern $bg');
              expect(MeowTokens.contrast(t.t1, bg), greaterThanOrEqualTo(4.5), reason: '$b $pattern $bg');
            }
          }
        }
      }
    });

    test('磨砂 < 0.5：垫层上限跟着降（0 不垫，正文不再保证）；次级字与强调色仍按 0.5 那一档的卡片修正，不被推成近黑 / 近白', () {
      for (final b in Brightness.values) {
        final dark = b == Brightness.dark;
        for (final base in looks) {
          for (final pattern in MeowBgPattern.values) {
            for (final f in const [0.0, 0.25]) {
              for (final (_, accent) in MeowAccentColors.presets) {
                final t = MeowTokens.resolve(b, with2(base, pattern: pattern, frost: f, accent: accent));
                final spec = t.backdrop!;
                final w = MeowBackdrop.frostWeight(f);
                if (dark) {
                  expect(t.backdropScrim, lessThanOrEqualTo(0.85 * w + 1e-9));
                } else {
                  final bottom = spec.fill.bottom;
                  expect(1 - (1 - t.backdropScrim) * (1 - bottom), lessThanOrEqualTo(bottom + (0.85 - bottom) * w + 1e-9));
                }
                final why = '$b ${base.cardColor.toRadixString(16)} $pattern f=$f accent=$accent';
                for (final surface in spec.referenceSurfaces(t.t1)) {
                  expect(MeowTokens.contrast(t.t2, surface), greaterThanOrEqualTo(4.5), reason: why);
                  expect(MeowTokens.contrast(t.accent, surface), greaterThanOrEqualTo(4.5), reason: why);
                }
                // 和 0.5 那一档比，强调色不会被推远（同一组背景，只是罩色 / 饱和度不同）
                final ref = MeowTokens.resolve(b, with2(base, pattern: pattern, frost: 0.5, accent: accent));
                expect(
                  (t.accent.computeLuminance() - ref.accent.computeLuminance()).abs(),
                  lessThan(0.12),
                  reason: why,
                );
              }
            }
          }
        }
      }
    });

    test('垫层：背景够亮 / 够暗时不垫；浅色垫白、深色垫黑，封顶 0.85', () {
      const texts = [(Color(0xFF2A2130), 7.0), (Color(0xFF665A69), 4.5)];
      expect(MeowBackdrop.scrimFor(worst: const Color(0xFFF0F0F0), fillAlpha: 0.34, dark: false, texts: texts), 0);
      final s = MeowBackdrop.scrimFor(worst: const Color(0xFF202020), fillAlpha: 0.34, dark: false, texts: texts);
      expect(s, greaterThan(0));
      expect(1 - (1 - s) * (1 - 0.34), lessThanOrEqualTo(0.85 + 1e-9));
      const light = [(Color(0xFFF7F0F3), 7.0)];
      expect(MeowBackdrop.scrimFor(worst: const Color(0xFF101010), fillAlpha: 0.07, dark: true, texts: light), 0);
      expect(MeowBackdrop.scrimFor(worst: const Color(0xFFB0B0B0), fillAlpha: 0.07, dark: true, texts: light), greaterThan(0));
    });

    test('插画是自己选的图：保守极值从纯黑到纯白都有', () {
      final lum = MeowBackdrop.artExtremes.map((c) => c.computeLuminance()).toList();
      expect(lum.reduce(math.min), 0);
      expect(lum.reduce(math.max), 1);
    });

    test('设置：老配置没有背景 / 磨砂两项 = 光斑 + 0.5；存了再读回来一样；经典主题下外观不带它们', () {
      final old = MeowSettings.fromJson({'themeStyle': 'glass'});
      expect((old.bgPattern, old.glassFrost), (MeowBgPattern.blobs, 0.5));
      const s = MeowSettings(themeStyle: MeowThemeStyle.glass, bgPattern: MeowBgPattern.art, glassFrost: 0.2);
      final back = MeowSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect((back.bgPattern, back.glassFrost), (MeowBgPattern.art, 0.2));
      expect(MeowSettings.fromJson({'bgPattern': 'stars'}).bgPattern, MeowBgPattern.blobs);
      expect(MeowLook.of(s.copyWith(themeStyle: MeowThemeStyle.classic)), MeowLook.classic);
      // 插画只用自己选的图：还没选时先按光斑画；选了带上编号（换图 = 外观变了 → 重画背景）
      expect(MeowLook.of(s).bgPattern, MeowBgPattern.blobs);
      final withArt = s.copyWith(glassArtImage: 'a1b2c3d4');
      expect((MeowLook.of(withArt).bgPattern, MeowLook.of(withArt).artImage), (MeowBgPattern.art, 'a1b2c3d4'));
      expect(MeowLook.of(withArt.copyWith(bgPattern: MeowBgPattern.blobs)).artImage, isNull);
      expect(MeowLook.of(withArt) == MeowLook.of(withArt.copyWith(glassArtImage: 'ffff0000')), isFalse);
      final back2 = MeowSettings.fromJson(jsonDecode(jsonEncode(withArt.toJson())) as Map<String, Object?>);
      expect(back2.glassArtImage, 'a1b2c3d4');
      expect(MeowSettings.fromJson({'themeStyle': 'glass'}).glassArtImage, isNull);
    });
  });

  group('控件：液态玻璃 / 经典', () {
    testWidgets('右上角圆钮与胶囊：玻璃下换成玻璃，实底主操作不是逐颗的玻璃（静态半透明，见 button_fill_test）；经典下仍是实色、不多玻璃', (tester) async {
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
        reason: '实底的主操作是静态半透明，不挂玻璃',
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

    testWidgets('电源键：玻璃下盖一块玻璃（圆角方块，不是正圆），经典下没有（底与液面见 button_fill_test）', (tester) async {
      Widget power() => MeowPowerButton(on: true, onTap: () {});
      await tester.pumpWidget(_app(power()));
      expect(find.byType(MeowGlassBox), findsNothing);
      await tester.pumpWidget(_app(power(), glass: true));
      await tester.pumpAndSettle();
      final box = tester.widget<MeowGlassBox>(find.byType(MeowGlassBox));
      expect(box.radius, BorderRadius.circular(80 * 0.325));
      expect(box.style.tint.a, lessThan(0.2), reason: '几乎不着色：颜色来自背后的卡片与液面');
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
