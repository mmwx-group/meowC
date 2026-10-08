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
  );

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
    );
  }
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
