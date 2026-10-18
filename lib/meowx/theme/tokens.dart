import 'dart:math' as math;

import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';

/// MeowX 颜色 token：与 iOS / iPad 改版同一套——奶白底、白卡片、樱粉主卡、墨色强调
/// （设计稿 design/ui-redesign/boards 里的 --bg / --card / --card2 / --hero / --btnon / --ink / --ink2 / --soft / --rose …）。
@immutable
class MeowTokens extends ThemeExtension<MeowTokens> {
  const MeowTokens({
    required this.bg,
    required this.elev,
    required this.card2,
    required this.hero,
    required this.btnOn,
    required this.onBtn,
    required this.soft,
    required this.pink,
    required this.line,
    required this.t1,
    required this.t2,
    required this.t3,
    required this.accent,
    required this.onAccent,
    required this.pur,
    required this.orange,
    required this.good,
    required this.mid,
    required this.slow,
    required this.down,
    required this.teal,
    required this.gold,
    required this.silver,
    required this.glassTint,
    required this.glassEdge,
    required this.cardEdge,
    this.glass = false,
    this.glassTinted = false,
    this.heroGradient,
    required this.onHero,
    required this.heroTrack,
    required this.glassPanel,
    required this.fill,
  });

  /// 页面底 / 卡片底 / 卡片里的次级底（徽标、未选分段、进度槽）
  final Color bg, elev, card2;

  /// 连接主卡、当前组摘要这类「主卡」的樱粉底；已连接时的电源键 / 打开的开关（[onBtn] 是画在它上面的图标色）
  final Color hero, btnOn, onBtn;

  /// 选中态的柔粉底（配 [accent] 的字和描边）、进度条的粉、1px 分隔线
  final Color soft, pink, line;

  /// 文本：墨色正文 [t1]、次级 [t2]（[t3] 与 t2 同值，保留给旧调用点）
  final Color t1, t2, t3;

  /// 强调色 = 玫红（选中的字 / 描边 / 链接）；[onAccent] 是放在强调色实底上的字色。
  /// 实心主按钮与选中分段用墨色 [t1] 配 [bg]，不用强调色。
  final Color accent, onAccent;

  /// 紫（下载 / 嵌套组 / UDP）、警示橙、绿 / 橙 / 红（延迟三档与状态）、下载紫、青
  final Color pur, orange, good, mid, slow, down, teal;

  /// 回程奖牌金 / 银
  final Color gold, silver;

  /// 搜索框等的底与描边基色
  final Color glassTint, glassEdge;

  /// 卡片描边：新主题白卡放在奶白底上自带对比，不描边（透明）；保留字段给旧调用点
  final Color cardEdge;

  /// 液态玻璃主题（[glassTinted] = 玻璃样式选了「着色」）。玻璃只画在浮在内容上面的控件层（右上角圆钮、菜单、底部卡片、
  /// 电源键、首页模式分段的滑块），真正画不画还要看外层的玻璃宿主（见 glass.dart 的 [meowGlassOn]）；内容卡片两种主题都是实色。
  final bool glass, glassTinted;

  /// 连接主卡（已连接时）的斜向渐变：只有液态玻璃主题有，经典是平涂 [hero]
  final Gradient? heroGradient;

  /// 主卡上的「当前节点」行与「规则 | 全局 | 直连」分段的槽：经典 = 卡片底；液态玻璃 = 半透明白，不挡主卡的底色
  final Color onHero, heroTrack;

  /// 玻璃底部卡片里的分组卡：经典 = 卡片底；液态玻璃 = 半透明白
  final Color glassPanel;

  /// 进度条之类的强调填充（订阅用量）：跟着强调色走；缺省就是原来的粉 #F3A6BF。
  /// [pink] 仍是跟连接主卡 / 电源键绑定的那份粉（电源键连上时的光晕），随启动卡片颜色变
  final Color fill;

  static const light = MeowTokens(
    bg: Color(0xFFEFE8DF),
    elev: Color(0xFFFFFFFF),
    card2: Color(0xFFF3EDE6),
    hero: Color(0xFFF7CDDB),
    btnOn: Color(0xFFE77FA6),
    onBtn: Color(0xFF2A2130),
    soft: Color(0xFFFCE4EC),
    pink: Color(0xFFF3A6BF),
    line: Color(0x1A2A2130),
    t1: Color(0xFF2A2130),
    t2: Color(0xFF665A69),
    t3: Color(0xFF665A69),
    accent: Color(0xFFB02E63),
    onAccent: Color(0xFFFFFFFF),
    pur: Color(0xFF5B45B0),
    orange: Color(0xFF9A5200),
    good: Color(0xFF17693F),
    mid: Color(0xFF9A5200),
    slow: Color(0xFFB93228),
    down: Color(0xFF5B45B0),
    teal: Color(0xFF1F6F80),
    gold: Color(0xFFA8700A),
    silver: Color(0xFF6E7480),
    glassTint: Color(0xFFFFFFFF),
    glassEdge: Color(0xFF2A2130),
    cardEdge: Color(0x00000000),
    onHero: Color(0xFFFFFFFF),
    heroTrack: Color(0xFFFFFFFF),
    glassPanel: Color(0xFFFFFFFF),
    fill: Color(0xFFF3A6BF),
  );

  static const dark = MeowTokens(
    bg: Color(0xFF0E0C11),
    elev: Color(0xFF221C29),
    card2: Color(0xFF2F2838),
    hero: Color(0xFF45283A),
    btnOn: Color(0xFFF3A6BF),
    onBtn: Color(0xFF2A2130),
    soft: Color(0x29F3A6BF),
    pink: Color(0xFFF3A6BF),
    line: Color(0x1AFFFFFF),
    t1: Color(0xFFF7F0F3),
    t2: Color(0xFFB9ADBB),
    t3: Color(0xFFB9ADBB),
    accent: Color(0xFFF7B6CB),
    onAccent: Color(0xFF2A2130),
    pur: Color(0xFFB3A2FF),
    orange: Color(0xFFF2B257),
    good: Color(0xFF57D292),
    mid: Color(0xFFF2B257),
    slow: Color(0xFFFF8377),
    down: Color(0xFFB3A2FF),
    teal: Color(0xFF7CCFE0),
    gold: Color(0xFFE0B040),
    silver: Color(0xFFAEB4C0),
    glassTint: Color(0xFF221C29),
    glassEdge: Color(0xFFFFFFFF),
    cardEdge: Color(0x00000000),
    onHero: Color(0xFF221C29),
    heroTrack: Color(0xFF221C29),
    glassPanel: Color(0xFF221C29),
    fill: Color(0xFFF3A6BF),
  );

  /// 按外观设置（主题风格 / 玻璃样式 / 卡片颜色 / 启动卡片颜色 / 强调色）推出这一份 token。缺省外观就是 [light] / [dark] 本身（同一个实例）。
  /// 卡片颜色只管内容卡片；连接主卡与电源键跟启动卡片颜色；强调文字、选中态、进度条跟强调色；实心强调块与语义色（good / slow …）都不变。
  static MeowTokens resolve(Brightness brightness, MeowLook look) {
    final isDark = brightness == Brightness.dark;
    final base = isDark ? dark : light;
    if (look == MeowLook.classic) return base;
    final glass = look.glass;
    final shades = cardShades(Color(look.cardColor), dark: isDark, glass: glass);
    final hero = heroShades(Color(look.heroColor), dark: isDark);
    final accent = accentShades(Color(look.accentColor), dark: isDark);
    final g = MeowGlassSpec.of(isDark);
    return base
        .copyWith(
          bg: glass ? g.bg : null,
          elev: shades.card,
          card2: shades.card2,
          glassTint: isDark ? shades.card : null,
          glass: glass,
          glassTinted: glass && look.glassTint == MeowGlassTint.tinted,
          heroGradient: glass
              ? LinearGradient(begin: const Alignment(-0.5, -1), end: const Alignment(0.5, 1), colors: hero.gradient)
              : null,
          onHero: glass ? g.onHero : shades.card,
          heroTrack: glass ? g.heroTrack : shades.card,
          glassPanel: glass ? g.panel : shades.card,
        )
        ._withColors(hero: hero.hero, btnOn: hero.btnOn, pink: hero.pink, accent: accent.accent, soft: accent.soft, fill: accent.fill);
  }

  /// 启动卡片颜色 → 主卡底、电源键填充（同色相更饱和的一档）、电源键光晕的粉、液态玻璃下的斜向渐变（稍亮 → 稍深）。
  /// 浅色：直接用（亮度不到 80% 的提到 80%，墨色字才读得清）；深色：不直接用，取色相压成与原来 #45283A 同饱和度 / 亮度的深色。
  /// 缺省樱粉给回原来的值（渐变即 #FBDCE7 → #F2BED2 / #5A2C47 → #33202F）。
  static ({Color hero, Color btnOn, Color pink, List<Color> gradient}) heroShades(Color pick, {required bool dark}) {
    final base = dark ? MeowTokens.dark : light;
    if (pick.toARGB32() == MeowHeroColors.sakura) {
      return (hero: base.hero, btnOn: base.btnOn, pink: base.pink, gradient: MeowGlassSpec.of(dark).hero);
    }
    final hsl = HSLColor.fromColor(pick.withValues(alpha: 1));
    final h = hsl.hue, s = hsl.saturation;
    // 电源键：浅色亮度 70%（原来的 #E77FA6）、深色 80%（原来的 #F3A6BF）；饱和度取所选色的，夹在 0.35–0.78（灰色卡配灰一点的键）
    final btnS = s < 0.08 ? s : s.clamp(0.35, 0.78);
    final pink = HSLColor.fromAHSL(1, h, btnS, 0.80).toColor();
    if (!dark) {
      final l = hsl.lightness.clamp(0.80, 0.94);
      final heroS = s.clamp(0.0, 0.85);
      return (
        hero: hsl.lightness >= 0.80 && hsl.lightness <= 0.94 ? pick.withValues(alpha: 1) : HSLColor.fromAHSL(1, h, heroS, l).toColor(),
        btnOn: HSLColor.fromAHSL(1, h, btnS, 0.70).toColor(),
        pink: pink,
        gradient: [
          HSLColor.fromAHSL(1, h, heroS, (l + 0.04).clamp(0.0, 0.97)).toColor(),
          HSLColor.fromAHSL(1, h, heroS, l - 0.04).toColor(),
        ],
      );
    }
    return (
      hero: HSLColor.fromAHSL(1, h, s.clamp(0.0, 0.27), 0.21).toColor(),
      btnOn: pink,
      pink: pink,
      gradient: [
        HSLColor.fromAHSL(1, h, s.clamp(0.0, 0.34), 0.26).toColor(),
        HSLColor.fromAHSL(1, h, s.clamp(0.0, 0.23), 0.16).toColor(),
      ],
    );
  }

  /// 强调色 → 强调字色（对比度自动修正）、选中态淡底、进度条填充。
  /// 浅色：在页面底与白卡上都 ≥ 4.5:1，不够就压暗；淡底是同色相很淡的实色。
  /// 深色：在深色底与卡片上 ≥ 4.5:1，不够就提亮（起点至少 78% 亮度，与原来的 #F7B6CB 一族）；淡底是半透明。缺省玫红给回原来的值。
  static ({Color accent, Color soft, Color fill}) accentShades(Color pick, {required bool dark}) {
    final base = dark ? MeowTokens.dark : light;
    if (pick.toARGB32() == MeowAccentColors.rose) return (accent: base.accent, soft: base.soft, fill: base.fill);
    final hsl = HSLColor.fromColor(pick.withValues(alpha: 1));
    final h = hsl.hue, s = hsl.saturation.clamp(0.0, 0.8);
    final fill = HSLColor.fromAHSL(1, h, s, dark ? 0.75 : 0.80).toColor();
    if (!dark) {
      return (
        accent: ensureContrast(pick.withValues(alpha: 1), const [Color(0xFFEFE8DF), Color(0xFFFFFFFF)], lighten: false),
        soft: HSLColor.fromAHSL(1, h, s, 0.94).toColor(),
        fill: fill,
      );
    }
    final start = HSLColor.fromAHSL(1, h, s, hsl.lightness.clamp(0.78, 1.0)).toColor();
    return (
      accent: ensureContrast(start, const [Color(0xFF0E0C11), Color(0xFF221C29), Color(0xFF2F2838)], lighten: true),
      soft: HSLColor.fromAHSL(0.16, h, s, 0.80).toColor(),
      fill: fill,
    );
  }

  /// WCAG 对比度。
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// 把 [c] 沿亮度压暗（[lighten] = 提亮）到与 [against] 里每个颜色的对比度都 ≥ [ratio]，色相与饱和度不变。
  static Color ensureContrast(Color c, List<Color> against, {required bool lighten, double ratio = 4.5}) {
    bool ok(Color x) => against.every((b) => contrast(x, b) >= ratio);
    if (ok(c)) return c;
    final hsl = HSLColor.fromColor(c);
    for (var l = hsl.lightness; lighten ? l <= 1 : l >= 0; l += lighten ? 0.01 : -0.01) {
      final x = hsl.withLightness(l.clamp(0.0, 1.0)).toColor();
      if (ok(x)) return x;
    }
    return lighten ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  }

  MeowTokens _withColors({
    required Color hero,
    required Color btnOn,
    required Color pink,
    required Color accent,
    required Color soft,
    required Color fill,
  }) => MeowTokens(
    bg: bg,
    elev: elev,
    card2: card2,
    hero: hero,
    btnOn: btnOn,
    onBtn: onBtn,
    soft: soft,
    pink: pink,
    line: line,
    t1: t1,
    t2: t2,
    t3: t3,
    accent: accent,
    onAccent: onAccent,
    pur: pur,
    orange: orange,
    good: good,
    mid: mid,
    slow: slow,
    down: down,
    teal: teal,
    gold: gold,
    silver: silver,
    glassTint: glassTint,
    glassEdge: glassEdge,
    cardEdge: cardEdge,
    glass: glass,
    glassTinted: glassTinted,
    heroGradient: heroGradient,
    onHero: onHero,
    heroTrack: heroTrack,
    glassPanel: glassPanel,
    fill: fill,
  );

  /// 卡片色 → 卡片底（[MeowTokens.elev]）与卡片里的次级底（[MeowTokens.card2]）。
  /// 浅色：直接用所选色（亮度低于 88% 的提到 88%、饱和度最多 70%），次级底同色相再深 5%；
  /// 深色：不直接用，取色相压成深色卡（饱和度 ≤ 28%、亮度 14%，次级底 ≤ 26% / 20%）；
  /// 选「白」时保持原来的两档（液态玻璃的深色是更中性的 #1C1A20 / #2A2730，配纯黑底）。
  static ({Color card, Color card2}) cardShades(Color pick, {required bool dark, bool glass = false}) {
    if (pick.toARGB32() == MeowCardColors.white) {
      if (!dark) return (card: light.elev, card2: light.card2);
      return glass
          ? (card: const Color(0xFF1C1A20), card2: const Color(0xFF2A2730))
          : (card: MeowTokens.dark.elev, card2: MeowTokens.dark.card2);
    }
    final opaque = pick.withValues(alpha: 1);
    final hsl = HSLColor.fromColor(opaque);
    final h = hsl.hue, s = hsl.saturation.clamp(0.0, 0.7);
    if (!dark) {
      // 够亮的（预设都是）原样用；太暗的提亮到 88%
      final l = hsl.lightness.clamp(0.88, 1.0);
      return (
        card: hsl.lightness >= 0.88 ? opaque : HSLColor.fromAHSL(1, h, s, l).toColor(),
        card2: HSLColor.fromAHSL(1, h, (s + 0.08).clamp(0.0, 0.7), l - 0.05).toColor(),
      );
    }
    return (
      card: HSLColor.fromAHSL(1, h, s.clamp(0.0, 0.28), 0.14).toColor(),
      card2: HSLColor.fromAHSL(1, h, s.clamp(0.0, 0.26), 0.20).toColor(),
    );
  }

  @override
  MeowTokens copyWith({
    Color? bg,
    Color? elev,
    Color? card2,
    Color? glassTint,
    bool? glass,
    bool? glassTinted,
    Gradient? heroGradient,
    Color? onHero,
    Color? heroTrack,
    Color? glassPanel,
  }) => MeowTokens(
    bg: bg ?? this.bg,
    elev: elev ?? this.elev,
    card2: card2 ?? this.card2,
    hero: hero,
    btnOn: btnOn,
    onBtn: onBtn,
    soft: soft,
    pink: pink,
    line: line,
    t1: t1,
    t2: t2,
    t3: t3,
    accent: accent,
    onAccent: onAccent,
    pur: pur,
    orange: orange,
    good: good,
    mid: mid,
    slow: slow,
    down: down,
    teal: teal,
    gold: gold,
    silver: silver,
    glassTint: glassTint ?? this.glassTint,
    glassEdge: glassEdge,
    cardEdge: cardEdge,
    glass: glass ?? this.glass,
    glassTinted: glassTinted ?? this.glassTinted,
    heroGradient: heroGradient ?? this.heroGradient,
    onHero: onHero ?? this.onHero,
    heroTrack: heroTrack ?? this.heroTrack,
    glassPanel: glassPanel ?? this.glassPanel,
    fill: fill,
  );

  @override
  MeowTokens lerp(ThemeExtension<MeowTokens>? other, double t) {
    if (other is! MeowTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return MeowTokens(
      bg: c(bg, other.bg),
      elev: c(elev, other.elev),
      card2: c(card2, other.card2),
      hero: c(hero, other.hero),
      btnOn: c(btnOn, other.btnOn),
      onBtn: c(onBtn, other.onBtn),
      soft: c(soft, other.soft),
      pink: c(pink, other.pink),
      line: c(line, other.line),
      t1: c(t1, other.t1),
      t2: c(t2, other.t2),
      t3: c(t3, other.t3),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      pur: c(pur, other.pur),
      orange: c(orange, other.orange),
      good: c(good, other.good),
      mid: c(mid, other.mid),
      slow: c(slow, other.slow),
      down: c(down, other.down),
      teal: c(teal, other.teal),
      gold: c(gold, other.gold),
      silver: c(silver, other.silver),
      glassTint: c(glassTint, other.glassTint),
      glassEdge: c(glassEdge, other.glassEdge),
      cardEdge: c(cardEdge, other.cardEdge),
      // 两种主题之间不插值：过一半就换成另一边的
      glass: t < 0.5 ? glass : other.glass,
      glassTinted: t < 0.5 ? glassTinted : other.glassTinted,
      heroGradient: Gradient.lerp(heroGradient, other.heroGradient, t),
      onHero: c(onHero, other.onHero),
      heroTrack: c(heroTrack, other.heroTrack),
      glassPanel: c(glassPanel, other.glassPanel),
      fill: c(fill, other.fill),
    );
  }
}

/// 外观设置里决定颜色 token 的几项（见 [MeowTokens.resolve]）。
@immutable
class MeowLook {
  const MeowLook({
    this.style = MeowThemeStyle.classic,
    this.glassTint = MeowGlassTint.clear,
    this.cardColor = MeowCardColors.white,
    this.heroColor = MeowHeroColors.sakura,
    this.accentColor = MeowAccentColors.rose,
  });

  /// 从设置里取（经典主题下玻璃样式不影响任何东西，一律记成缺省，切样式时不白建主题）
  factory MeowLook.of(MeowSettings s) => MeowLook(
    style: s.themeStyle,
    glassTint: s.themeStyle == MeowThemeStyle.glass ? s.glassTint : MeowGlassTint.clear,
    cardColor: s.cardColor,
    heroColor: s.heroColor,
    accentColor: s.accentColor,
  );

  /// 缺省外观：经典 + 白卡 + 樱粉主卡 + 玫红强调，就是改版前的样子
  static const classic = MeowLook();

  final MeowThemeStyle style;
  final MeowGlassTint glassTint;

  /// ARGB
  final int cardColor, heroColor, accentColor;

  bool get glass => style == MeowThemeStyle.glass;

  @override
  bool operator ==(Object other) =>
      other is MeowLook &&
      other.style == style &&
      other.glassTint == glassTint &&
      other.cardColor == cardColor &&
      other.heroColor == heroColor &&
      other.accentColor == accentColor;

  @override
  int get hashCode => Object.hash(style, glassTint, cardColor, heroColor, accentColor);
}

/// 卡片颜色的预设（「我的 › 外观 › 卡片颜色」，与设计稿同一组）；预设以外的就是自定义取色。
abstract final class MeowCardColors {
  static const white = 0xFFFFFFFF;
  static const presets = <(String, int)>[
    ('白', white),
    ('奶油', 0xFFFFF6EA),
    ('樱粉', 0xFFFFEFF4),
    ('薄荷', 0xFFECF8F1),
    ('雾蓝', 0xFFEDF3FB),
    ('薰衣草', 0xFFF3EFFC),
  ];

  /// 预设名；自定义的返回 null
  static String? nameOf(int color) => presets.where((p) => p.$2 == color).firstOrNull?.$1;
}

/// 启动卡片（连接主卡）颜色的预设；缺省樱粉 = 原来的主卡色。
abstract final class MeowHeroColors {
  static const sakura = 0xFFF7CDDB;
  static const presets = <(String, int)>[
    ('樱粉', sakura),
    ('珊瑚', 0xFFFBD3C7),
    ('薄荷', 0xFFCDEBDD),
    ('雾蓝', 0xFFCFDDF3),
    ('薰衣草', 0xFFDED4F5),
    ('奶茶', 0xFFEBDCCB),
  ];

  static String? nameOf(int color) => presets.where((p) => p.$2 == color).firstOrNull?.$1;
}

/// 强调色的预设；缺省玫红 = 原来的强调色。
abstract final class MeowAccentColors {
  static const rose = 0xFFB02E63;
  static const presets = <(String, int)>[
    ('玫红', rose),
    ('紫', 0xFF6A4BC4),
    ('蓝', 0xFF2F6FD0),
    ('青', 0xFF1F7F8C),
    ('绿', 0xFF2E7D4F),
    ('橙', 0xFFB55A12),
  ];

  static String? nameOf(int color) => presets.where((p) => p.$2 == color).firstOrNull?.$1;
}

/// 液态玻璃主题下改的几种颜色（经典主题不用）：更亮更素的浅色底 / 纯黑深色底（同 iOS，玻璃的高光与亮边才显得出来）、
/// 连接主卡的斜向渐变、主卡上的半透明白（节点行 / 分段槽）、底部卡片里分组卡的半透明白。
@immutable
class MeowGlassSpec {
  const MeowGlassSpec._({
    required this.bg,
    required this.hero,
    required this.onHero,
    required this.heroTrack,
    required this.panel,
  });

  final Color bg;
  final List<Color> hero;
  final Color onHero, heroTrack, panel;

  static const light = MeowGlassSpec._(
    bg: Color(0xFFF5F1EC),
    hero: [Color(0xFFFBDCE7), Color(0xFFF2BED2)],
    onHero: Color(0x9EFFFFFF), // 白 62%
    heroTrack: Color(0x66FFFFFF), // 白 40%
    panel: Color(0x8CFFFFFF), // 白 55%
  );

  static const dark = MeowGlassSpec._(
    bg: Color(0xFF000000),
    hero: [Color(0xFF5A2C47), Color(0xFF33202F)],
    onHero: Color(0x14FFFFFF), // 白 8%
    heroTrack: Color(0x14FFFFFF),
    panel: Color(0x12FFFFFF), // 白 7%
  );

  static MeowGlassSpec of(bool dark) => dark ? MeowGlassSpec.dark : MeowGlassSpec.light;
}

/// 字号阶梯（与 iOS 端一致）。等宽用于延迟、字节、规则、YAML。
class MeowFont {
  MeowFont._();

  /// 页标题（设计稿 26；旧主题是 34）
  static const pageTitle = 26.0;
  static const largeTitle = 34.0;
  static const title2 = 22.0;
  static const title3 = 20.0;
  static const headline = 17.0;
  static const body = 17.0;
  static const callout = 16.0;
  static const subheadline = 15.0;
  static const footnote = 13.0;
  static const caption = 12.0;
  static const caption2 = 11.0;

  static const monoFamily = 'monospace';
  static const monoFallback = ['Consolas', 'Menlo', 'Roboto Mono', 'monospace', 'Twemoji'];

  static TextStyle mono({
    double size = footnote,
    FontWeight weight = FontWeight.w400,
    Color? color,
  }) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color,
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

extension MeowContext on BuildContext {
  MeowTokens get mm =>
      Theme.of(this).extension<MeowTokens>() ??
      (Theme.of(this).brightness == Brightness.dark ? MeowTokens.dark : MeowTokens.light);

  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;
}
