import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';

import 'm3.dart';

/// Linux 的中文回落：系统的 Noto Sans CJK（Ubuntu 等桌面自带，名字和 meowRounded 里的 Noto Sans SC 不一样），没有就用随包的
/// HarmonyOS Sans（简体）。linux-arm64 的 Flutter 不会自己回落到系统字体（amd64 会），不写进回落列表的中文全是方框
/// （2026-11 在干净的 Ubuntu 22.04 / 24.04 上实测）。其它平台为空，渲染不变。
final linuxCjkFallback = Platform.isLinux ? const <String>['Noto Sans CJK SC', 'HarmonyOS_Sans'] : const <String>[];

/// 主题的回落（Linux）；另起一份、不继承主题的文字样式（`AnimatedDefaultTextStyle` 直接给的 TextStyle）也要带上它。
/// 其它平台 null：主题与这些样式都同以前。
final List<String>? linuxTextFallback = linuxCjkFallback.isEmpty ? null : [...linuxCjkFallback, 'Twemoji'];

/// 改版前的颜色 token（`context.mm`）。2026-11 起界面改成 Material 3 Expressive，这些值全部由 [ColorScheme] 推出来
/// （[MeowTokens.fromScheme]），旧页面先跟着换色；新写的代码直接用 `context.cs` / `context.m3`（见 m3.dart），
/// 页面全部改完后删掉这一层。
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
    required this.onHero,
    required this.heroTrack,
    required this.glassPanel,
    required this.fill,
    required this.elevSolid,
  });

  /// 页面底 / 卡片底 / 卡片里的次级底（徽标、未选分段、进度槽）
  final Color bg, elev, card2;

  /// 主卡底（primaryContainer）、实心强调块（primary）与上面的字
  final Color hero, btnOn, onBtn;

  /// 选中态的淡底（secondaryContainer）、强调填充、分隔线
  final Color soft, pink, line;

  /// 文本：正文 [t1]、次级 [t2]（[t3] 与 t2 同值，保留给旧调用点）
  final Color t1, t2, t3;

  /// 强调色（primary）与放在它上面的字
  final Color accent, onAccent;

  /// 第三色（tertiary）、警示、通 / 慢 / 超时、下载、青
  final Color pur, orange, good, mid, slow, down, teal;

  /// 回程奖牌金 / 银
  final Color gold, silver;

  /// 搜索框等的底与描边基色
  final Color glassTint, glassEdge;

  /// 卡片描边（透明）
  final Color cardEdge;

  /// 主卡上的「当前节点」行与分段槽、底部弹层里的分组卡
  final Color onHero, heroTrack, glassPanel;

  /// 进度条之类的强调填充
  final Color fill;

  /// 浮层（对话框、弹出菜单、底部弹层）的不透明底
  final Color elevSolid;

  /// 卡片上选中态的底
  Color get selectedCard => soft;

  /// 由色板推出旧 token：页面底 = surface、卡片 = surfaceContainerLow、次级底 = surfaceContainerHigh、主卡 = primaryContainer……
  factory MeowTokens.fromScheme(ColorScheme cs) {
    final x = MeowM3.from(cs);
    final dark = cs.brightness == Brightness.dark;
    return MeowTokens(
      bg: cs.surface,
      elev: cs.card,
      card2: cs.cardInner,
      hero: cs.primaryContainer,
      btnOn: cs.primary,
      onBtn: cs.onPrimary,
      soft: cs.secondaryContainer,
      pink: cs.primary,
      line: cs.outlineVariant,
      t1: cs.onSurface,
      t2: cs.onSurfaceVariant,
      t3: cs.onSurfaceVariant,
      accent: cs.primary,
      onAccent: cs.onPrimary,
      pur: cs.tertiary,
      orange: x.warn,
      good: x.ok,
      mid: x.warn,
      slow: cs.error,
      down: cs.tertiary,
      teal: x.info,
      gold: dark ? const Color(0xFFE0B040) : const Color(0xFFA8700A),
      silver: dark ? const Color(0xFFAEB4C0) : const Color(0xFF6E7480),
      glassTint: cs.surfaceContainerHighest,
      glassEdge: cs.outline,
      cardEdge: const Color(0x00000000),
      onHero: cs.surfaceContainerLowest.withValues(alpha: 0.72),
      heroTrack: cs.surfaceContainerLowest.withValues(alpha: 0.72),
      glassPanel: cs.surfaceContainer,
      fill: cs.primary,
      elevSolid: cs.card,
    );
  }

  /// 测试与没有主题的地方用的缺省（品牌玫瑰色板）
  static final light = MeowTokens.fromScheme(MeowColors.scheme(MeowColors.brandSeed, Brightness.light));
  static final dark = MeowTokens.fromScheme(MeowColors.scheme(MeowColors.brandSeed, Brightness.dark));

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

  @override
  MeowTokens copyWith() => this;

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
      onHero: c(onHero, other.onHero),
      heroTrack: c(heroTrack, other.heroTrack),
      glassPanel: c(glassPanel, other.glassPanel),
      fill: c(fill, other.fill),
      elevSolid: c(elevSolid, other.elevSolid),
    );
  }
}

/// 外观设置里决定色板的两项：主题色（种子）与跟随系统取色。
@immutable
class MeowLook {
  const MeowLook({this.seed = 0xFFB02E63, this.followSystem = false});

  factory MeowLook.of(MeowSettings s) => MeowLook(seed: s.accentColor, followSystem: s.followSystemColor);

  /// 缺省：品牌玫瑰、不跟随系统
  static const classic = MeowLook();

  /// ARGB
  final int seed;
  final bool followSystem;

  @override
  bool operator ==(Object other) => other is MeowLook && other.seed == seed && other.followSystem == followSystem;

  @override
  int get hashCode => Object.hash(seed, followSystem);
}

/// 字号阶梯（Material 3 type scale 的常用几档；改版前的名字沿用）。等宽用于延迟、字节、规则、YAML。
class MeowFont {
  MeowFont._();

  /// 页标题（M3 headline large 32；Expressive 用粗字重）
  static const pageTitle = 32.0;
  static const largeTitle = 36.0;
  static const title2 = 22.0;
  static const title3 = 20.0;
  static const headline = 16.0;
  static const body = 16.0;
  static const callout = 15.0;
  static const subheadline = 14.0;
  static const footnote = 13.0;
  static const caption = 12.0;
  static const caption2 = 11.0;

  static const monoFamily = 'monospace';
  static final monoFallback = ['Consolas', 'Menlo', 'Roboto Mono', 'monospace', ...linuxCjkFallback, 'Twemoji'];

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
