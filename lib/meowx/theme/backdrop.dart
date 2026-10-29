import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 液态玻璃主题的整屏背景（平涂 / 光斑 / 插画）与内容卡片的磨砂参数。纯值，按外观设置推出来，挂在 [MeowTokens.backdrop] 上。
///
/// 背景是静止的（不随滚动），所以卡片不做逐帧实时模糊：背景、尺寸、浅深、底色、磨砂强度变了时，把整屏背景按 [blurSigma] 与
/// [saturation] 预先渲染成一张小的模糊图（../app/backdrop_host.dart），每张卡片按自己在屏幕上的位置裁这张图的对应区域当底
/// （card_surface.dart 的 [MeowFrostBox]），看起来是真磨砂、开销接近零。
///
/// 取值与 iOS / macOS 同一份规格（设计预览「玻璃卡片重新设计」）：几何按 340 宽的手机等比缩放。
@immutable
class MeowBackdrop {
  const MeowBackdrop({
    required this.pattern,
    required this.dark,
    required this.hueA,
    required this.hueB,
    required this.base,
    required this.diagonal,
    required this.frost,
    this.artImage,
  });

  /// 按底色选择推：渐变用两端；单色时第二色 = 同色相 +28°（「白」取原来的页面底 #F5F1EC 的色相）。
  /// [base] 是平涂背景（与光斑的底）：单色平涂仍是原来自上而下的轻渐层，其余是两色的斜向渐变（[MeowTokens.glassGradientShades]）。
  factory MeowBackdrop.of(MeowLook look, {required bool dark}) {
    final gradient = look.bgStyle == MeowBgStyle.gradient;
    final white = !gradient && look.cardColor == MeowCardColors.white;
    final a = HSLColor.fromColor(
      gradient ? Color(look.gradientFrom) : (white ? MeowGlassSpec.light.bg : Color(look.cardColor).withValues(alpha: 1)),
    );
    final b = gradient ? HSLColor.fromColor(Color(look.gradientTo)) : a.withHue((a.hue + 28) % 360);
    final pattern = look.bgPattern;
    final List<Color> base;
    final bool diagonal;
    if (pattern == MeowBgPattern.flat) {
      final s = gradient
          ? MeowTokens.glassGradientShades(Color(look.gradientFrom), Color(look.gradientTo), dark: dark)
          : MeowTokens.glassShades(Color(look.cardColor), dark: dark);
      base = s.gradient ?? [s.bg, s.bg];
      diagonal = s.diagonal;
    } else {
      base = MeowTokens.glassGradientShades(a.toColor(), b.toColor(), dark: dark).gradient!;
      diagonal = true;
    }
    return MeowBackdrop(
      pattern: pattern,
      dark: dark,
      hueA: a.hue,
      hueB: b.hue,
      base: base,
      diagonal: diagonal,
      frost: look.glassFrost.clamp(0.0, 1.0),
      artImage: pattern == MeowBgPattern.art ? look.artImage : null,
    );
  }

  final MeowBgPattern pattern;
  final bool dark;

  /// 两种颜色的色相（光斑与插画的那层底色都只取色相）
  final double hueA, hueB;

  /// 底色渐层（平涂背景、光斑的底）；[diagonal] = 左上 → 右下，否则自上而下
  final List<Color> base;
  final bool diagonal;

  /// 磨砂强度 0–1
  final double frost;

  /// 插画背景的图片编号（自己选的图，见 glass_art.dart；换图就重画）。没选图时外观里已经退回光斑（[MeowLook.of]），这里不会是 null
  final String? artImage;

  /// 光斑与插画几何的参考宽度（设计稿的手机宽 340、高 720）
  static const refWidth = 340.0, refHeight = 720.0;

  /// 光斑的模糊（σ，dp，随屏幕缩放）
  static const blobSigma = 38.0;

  /// 插画铺满后四边再外扩的比例
  static const artBleed = 0.06;

  /// 磨砂强度的左半段（0–0.5）往「透明」走的程度：0.5 及以上 = 1（第一版的取值），0 = 0（几乎透明、不模糊、不加厚、没有罩色）。
  /// 第一版整段 0–1 都是磨砂：最低也有 14dp 模糊、对比度垫层又把卡片顶回 0.85（同 MeowX iOS，用户实报「调到最低也不是透明效果」）
  static double frostWeight(double frost) => frost.clamp(0.0, 0.5) / 0.5;

  /// 卡片背后那块背景的模糊（σ，dp）：f ≥ 0.5 是 14 + 30f；更低时从 29 线性降到 f = 0 的 1
  double get blurSigma => frost < 0.5 ? 1 + 28 * frostWeight(frost) : 14 + 30 * frost;

  /// 饱和度提升跟着左半段降到原色：透明的卡片底下就是页面本来的颜色
  double get saturation => 1 + ((dark ? 1.6 : 1.8) - 1) * frostWeight(frost);

  /// 卡片填充：白色自上而下的两档不透明度（不含对比度垫层）
  ({double top, double bottom}) get fill => fillOf(frost, dark: dark);

  /// f ≥ 0.5：浅 (0.24+0.36f+0.14) → (0.24+0.36f−0.08)，深 (0.10+0.12f) → (0.04+0.06f)；
  /// f < 0.5：从 0.5 那档线性降到 f = 0 的浅 (0.08, 0.02) / 深 (0.03, 0)
  static ({double top, double bottom}) fillOf(double frost, {required bool dark}) {
    final f = frost.clamp(0.0, 1.0);
    if (f < 0.5) {
      final k = frostWeight(f), hi = fillOf(0.5, dark: dark);
      final (loTop, loBottom) = dark ? (0.03, 0.0) : (0.08, 0.02);
      return (top: loTop + (hi.top - loTop) * k, bottom: loBottom + (hi.bottom - loBottom) * k);
    }
    return dark
        ? (top: 0.10 + 0.12 * f, bottom: 0.04 + 0.06 * f)
        : (top: 0.24 + 0.36 * f + 0.14, bottom: 0.24 + 0.36 * f - 0.08);
  }

  /// 卡片取样图每 dp 几个像素：跟着模糊走——模糊折成取样图的像素不少于 2，卡片按屏幕放大回去时才看不出格子；
  /// 最少 1/4（磨砂 ≥ 0.5 时模糊 29dp 以上，1/4 绰绰有余），最多屏幕像素比（磨砂拉到 0、模糊 1dp 时每 dp 2 像素）。
  /// 以前固定物理分辨率的 1/4：磨砂 0.5 时多占内存，磨砂调低后又不够清楚（同 MeowX iOS 2026-10-28 的改法）
  static double frostScaleFor(double blurSigma, double dpr) => math.min(math.max(dpr, 0.25), math.max(0.25, 2 / math.max(blurSigma, 0.01)));

  /// 有没有东西可模糊（平涂只有渐层，磨砂照样生效，只是看不出模糊）
  bool get textured => pattern != MeowBgPattern.flat;

  /// 光斑几何的缩放：按 340 × 720 的手机等比，宽屏不按宽度放大（取宽、高两个比例里小的那个）
  static double scaleOf(Size screen) => math.min(screen.width / refWidth, screen.height / refHeight);

  /// 四团光斑：圆心、半径（dp）、颜色（含不透明度）。①起始色 ②结束色 ③色相 340° ④两色相平均。
  List<({Offset center, double radius, Color color})> blobs(Size screen) {
    final s = scaleOf(screen), w = screen.width, h = screen.height;
    final sat = dark ? 0.55 : 0.75;
    final l = dark ? const [0.32, 0.28, 0.36] : const [0.78, 0.80, 0.84];
    final a = dark ? 0.75 : 0.9;
    Color c(double hue, double light, double alpha) => HSLColor.fromAHSL(alpha, hue % 360, sat, light).toColor();
    return [
      (center: Offset(50 * s, 180 * s), radius: 120 * s, color: c(hueA, l[0], a)),
      (center: Offset(w - 40 * s, 390 * s), radius: 130 * s, color: c(hueB, l[1], a)),
      (center: Offset(120 * s, h - 140 * s), radius: 100 * s, color: c(340, l[2], a * 0.8)),
      (center: Offset(w - 60 * s, 50 * s), radius: 80 * s, color: c(meanHue(hueA, hueB), l[2], a * 0.7)),
    ];
  }

  /// 两个色相的圆周平均（atan2(Σsin, Σcos)）：直接相加除二在跨 0° 时会偏到对面（蜜桃 · 樱粉出一团青色）
  static double meanHue(double a, double b) {
    final ra = a * math.pi / 180, rb = b * math.pi / 180;
    final h = math.atan2(math.sin(ra) + math.sin(rb), math.cos(ra) + math.cos(rb)) * 180 / math.pi;
    return (h + 360) % 360;
  }

  /// 插画上面压的那层底色（左上 → 右下，保字的对比度）：跟着磨砂强度的左半段淡掉，到 0 没有——用户拉到透明要看的是图片本身
  /// （同 MeowX iOS：罩色把对比度砍掉近一半，用户实报「插画背景很糊」）；≥ 0.5 不变
  List<Color> get veil {
    final k = frostWeight(frost);
    return dark
        ? [HSLColor.fromAHSL(0.55 * k, hueA, 0.5, 0.12).toColor(), HSLColor.fromAHSL(0.60 * k, hueB, 0.5, 0.07).toColor()]
        : [HSLColor.fromAHSL(0.35 * k, hueA, 0.5, 0.92).toColor(), HSLColor.fromAHSL(0.45 * k, hueB, 0.5, 0.88).toColor()];
  }

  /// 整屏底色渐层的着色器（屏幕坐标）
  Shader baseShader(Size screen) => _diagonalShader(screen, base, diagonal: diagonal);

  static Shader _diagonalShader(Size screen, List<Color> colors, {bool diagonal = true}) => ui.Gradient.linear(
    Offset.zero,
    diagonal ? Offset(screen.width, screen.height) : Offset(0, screen.height),
    colors,
  );

  /// 在屏幕坐标里画整张清晰的背景（[art] = 解码好的图片，插画背景没解码完时只画底色渐层）
  void paint(Canvas canvas, Size screen, {ui.Image? art}) {
    final rect = Offset.zero & screen;
    canvas.drawRect(rect, Paint()..shader = baseShader(screen));
    switch (pattern) {
      case MeowBgPattern.flat:
        break;
      case MeowBgPattern.blobs:
        final sigma = blobSigma * scaleOf(screen);
        for (final b in blobs(screen)) {
          canvas.drawCircle(
            b.center,
            b.radius,
            Paint()
              ..color = b.color
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
          );
        }
      case MeowBgPattern.art:
        if (art != null) {
          final dst = coverRect(Size(art.width.toDouble(), art.height.toDouble()), screen);
          canvas.drawImageRect(
            art,
            Offset.zero & Size(art.width.toDouble(), art.height.toDouble()),
            dst,
            Paint()..filterQuality = FilterQuality.medium,
          );
        }
        final v = veil;
        if (v.any((c) => c.a > 0)) canvas.drawRect(rect, Paint()..shader = _diagonalShader(screen, v));
    }
  }

  /// 插画 cover 铺满屏幕后四边再外扩 [artBleed]
  static Rect coverRect(Size image, Size screen) {
    final scale = math.max(screen.width / image.width, screen.height / image.height) * (1 + 2 * artBleed);
    final w = image.width * scale, h = image.height * scale;
    return Rect.fromCenter(center: screen.center(Offset.zero), width: w, height: h);
  }

  /// 卡片背后那块背景的饱和度提升（同 CSS saturate()：按 0.213 / 0.715 / 0.072 的加权保持明度）
  static List<double> saturateMatrix(double s) {
    const r = 0.213, g = 0.715, b = 0.072;
    return [
      r + (1 - r) * s, g - g * s, b - b * s, 0, 0, //
      r - r * s, g + (1 - g) * s, b - b * s, 0, 0,
      r - r * s, g - g * s, b + (1 - b) * s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// 对单个颜色做同样的饱和度提升（对比度测算用）
  static Color saturate(Color c, double s) {
    final m = saturateMatrix(s);
    double ch(int row) => (m[row * 5] * c.r + m[row * 5 + 1] * c.g + m[row * 5 + 2] * c.b).clamp(0.0, 1.0);
    return Color.from(alpha: 1, red: ch(0), green: ch(1), blue: ch(2));
  }

  /// 插画背景卡片底下最不利的颜色：图片是用户自己选的，什么都可能有，按纯黑到纯白取保守极值（以前内置品牌插画时是
  /// 那两张画模糊后量出来的这几种近黑 / 近白，留着：它们带一点色相，提饱和后比纯黑白更不利）。主题按它推文字色与垫层。
  static const artExtremes = <Color>[
    Color(0xFF000000),
    Color(0xFFFFFFFF),
    Color(0xFF16171C),
    Color(0xFF17171E),
    Color(0xFF181920),
    Color(0xFFF8F2F2),
    Color(0xFFFBF5F4),
    Color(0xFFFCF6F6),
  ];

  /// 整套卡片统一的对比度垫层：让正文 [t1] 在卡片背后最不利的背景上也 ≥ 7（只看正文；次级字与强调色由主题对卡片面压暗 / 提亮，
  /// 见 [MeowTokens.resolve]）。按背景整体算、不逐卡按位置变（逐卡算的话滚动时卡片会变）：光斑按估算的颜色集合，
  /// 插画按模糊后的亮度极值（[artExtremes]）。浅色 = 加厚白色填充，深色 = 白色填充下面垫一层黑，都封顶 0.85。
  /// 磨砂强度低于 0.5 时垫层的上限跟着降（[frostWeight]），到 0 不垫：用户要的是透明，正文对比度不再保证。
  double scrim(Color t1) => _scrimWith(t1, fill.bottom, frostWeight(frost));

  double _scrimWith(Color t1, double fillBottom, double weight) {
    // 上限：深色 = 黑垫层本身；浅色 = 白的总覆盖率（填充本身就算进去，所以从填充往 0.85 走）
    final cap = dark ? 0.85 * weight : fillBottom + (0.85 - fillBottom) * weight;
    var s = 0.0;
    for (final w in worstBackgrounds()) {
      s = math.max(s, scrimFor(worst: w, fillAlpha: fillBottom, dark: dark, texts: [(t1, 7.0)], cap: cap));
    }
    return s;
  }

  /// 垫层 [scrim] 之后，最不利的背景上卡片的颜色
  List<Color> cardSurfaces(double scrim) => [for (final w in worstBackgrounds()) cardSurface(w, scrim)];

  /// 次级字与强调色按哪些卡片面修正：磨砂 0.5 那一档的卡片（填充与垫层按 0.5 算，背景仍是此刻的）。
  /// 更低时卡片往透明走，照实际的面修正会同时顶着背景最暗与最亮处、两头顾不全，强调色被推成近乎纯黑（MeowX iOS 模拟器里看到过），
  /// 所以颜色不跟着磨砂强度的左半段变；≥ 0.5 就是 [cardSurfaces]。
  List<Color> referenceSurfaces(Color t1) {
    if (frost >= 0.5) return cardSurfaces(scrim(t1));
    final ref = fillOf(0.5, dark: dark).bottom;
    final s = _scrimWith(t1, ref, 1);
    return [for (final w in worstBackgrounds()) _surface(w, s, ref)];
  }

  /// 背景 [worst] 上卡片（垫层 [scrim] + 底部那档填充）的颜色
  Color cardSurface(Color worst, double scrim) => _surface(worst, scrim, fill.bottom);

  Color _surface(Color worst, double scrim, double fillBottom) => dark
      ? Color.alphaBlend(Colors.white.withValues(alpha: fillBottom), Color.lerp(worst, Colors.black, scrim)!)
      : Color.lerp(worst, Colors.white, 1 - (1 - scrim) * (1 - fillBottom))!;

  /// 卡片背后可能出现的最不利的背景色（已做饱和度提升）：底色渐层沿途、光斑叠在底色上的颜色、插画极值叠上那层底色。
  /// 模糊只会把颜色往中间拉，所以用未模糊的极值是保守的。
  /// [saturated] = 卡片背后那块（预模糊图提了饱和度）；false = 直接看到的页面背景。
  List<Color> worstBackgrounds({bool saturated = true}) {
    final samples = [for (var i = 0; i <= 8; i++) Color.lerp(base.first, base.last, i / 8)!];
    final List<Color> raw;
    switch (pattern) {
      case MeowBgPattern.flat:
        raw = samples;
      case MeowBgPattern.blobs:
        raw = [
          ...samples,
          for (final b in blobs(const Size(refWidth, refHeight)))
            for (final s in samples) Color.alphaBlend(b.color, s),
        ];
      case MeowBgPattern.art:
        final v = veil;
        raw = [
          for (final c in artExtremes)
            for (var i = 0; i <= 4; i++) Color.alphaBlend(Color.lerp(v.first, v.last, i / 4)!, c),
        ];
    }
    return saturated ? [for (final c in raw) saturate(c, saturation)] : raw;
  }

  /// 卡片的「对比度垫层」：卡片下面那块背景最不利的颜色 [worst] 叠上填充（底部那档，[fillAlpha]）后，
  /// 文字色 [texts]（颜色, 要求的对比度）不够时，在填充下面再垫一层：浅色垫白、深色垫黑。返回垫层的不透明度（0 = 不用）。
  /// 垫层与填充合起来的不透明度不超过 [cap]（浅色：白的总覆盖率；深色：黑垫层本身）。
  static double scrimFor({
    required Color worst,
    required double fillAlpha,
    required bool dark,
    required List<(Color, double)> texts,
    double cap = 0.85,
  }) {
    bool ok(Color surface) => texts.every((t) => MeowTokens.contrast(t.$1, surface) >= t.$2 - 1e-9);
    const white = Color(0xFFFFFFFF), black = Color(0xFF000000);
    Color surface(double scrim) => dark
        ? Color.alphaBlend(white.withValues(alpha: fillAlpha), Color.lerp(worst, black, scrim)!)
        : Color.lerp(worst, white, 1 - (1 - scrim) * (1 - fillAlpha))!;
    if (ok(surface(0))) return 0;
    final max = dark ? cap : (cap <= fillAlpha ? 0.0 : 1 - (1 - cap) / (1 - fillAlpha));
    for (var s = 0.02; s < max; s += 0.02) {
      if (ok(surface(s))) return s;
    }
    return max;
  }

  @override
  bool operator ==(Object other) =>
      other is MeowBackdrop &&
      other.pattern == pattern &&
      other.dark == dark &&
      other.hueA == hueA &&
      other.hueB == hueB &&
      other.diagonal == diagonal &&
      other.frost == frost &&
      other.artImage == artImage &&
      other.base.length == base.length &&
      Iterable.generate(base.length).every((i) => other.base[i] == base[i]);

  @override
  int get hashCode => Object.hash(pattern, dark, hueA, hueB, diagonal, frost, artImage, Object.hashAll(base));
}

/// 玻璃卡片的固定画法参数（与底栏同一套高光）
abstract final class MeowFrostStyle {
  /// 高光边 1.2dp，140° 方向四段：浅色 白 .98 → .35(38%) → .12(62%) → .70；深色 .55 → .10 → .04 → .28
  static const rimWidth = 1.2;
  static const rimStops = [0.0, 0.38, 0.62, 1.0];
  static List<Color> rim(bool dark) => [
    for (final a in dark ? const [0.55, 0.10, 0.04, 0.28] : const [0.98, 0.35, 0.12, 0.70])
      Colors.white.withValues(alpha: a),
  ];

  /// 顶部 1dp 内高光（浅 白 .95 / 深 白 .22）、底部 1dp 内暗边（浅 底色色相 α.10 / 深 黑 α.25）
  static Color spec(bool dark) => Colors.white.withValues(alpha: dark ? 0.22 : 0.95);
  static Color inner(bool dark, double hue) =>
      dark ? const Color(0x40000000) : HSLColor.fromAHSL(0.10, hue, 0.4, 0.5).toColor();

  /// 投影：浅 底色色相 L0.35 α.16 模糊 28 下移 10 + 一圈 1dp 小影；深 黑 α.35
  static Color drop(bool dark, double hue) =>
      dark ? const Color(0x59000000) : HSLColor.fromAHSL(0.16, hue, 0.35, 0.35).toColor();
  static const dropBlur = 28.0, dropDy = 10.0;

  /// 次级块（未选分段、进度槽、徽标底）
  static Color card2(bool dark) => Colors.white.withValues(alpha: dark ? 0.07 : 0.38);
}

/// 渲染好的背景：清晰的整屏背景 [sharp]（页面底用，屏幕坐标 × [sharpScale]）与卡片用的预模糊图 [frost]（× [frostScale]）。
class MeowBackdropImages {
  MeowBackdropImages({
    required this.spec,
    required this.screen,
    required this.sharp,
    required this.sharpScale,
    required this.frost,
    required this.frostScale,
    this.localScrim = false,
  });

  final MeowBackdrop spec;
  final Size screen;
  final ui.Image sharp, frost;
  final double sharpScale, frostScale;

  /// [frost] 里已经叠了局部垫层（[MeowScrimMap]）：卡片不再画整套统一的那层
  final bool localScrim;

  void dispose() {
    sharp.dispose();
    frost.dispose();
  }
}

/// 局部对比度垫层（2026-10-29，用户实报「自定义背景有的字和背景融在一起看不见」「卡片像熏黑的玻璃」）。
/// 以前整套卡片共用一个垫层，按整张背景最不利的那一点算（自选插画还按纯黑纯白算），压在亮处的卡片也跟着被压暗 / 蒙白；
/// 磨砂低于 0.5 时垫层又跟着降到 0，字落在图片暗处就看不见。现在按屏幕上每一小格（[cell]）背后的模糊背景各算
/// 「要垫多少，正文与次级字才看得清」，做成一张小遮罩叠进卡片用的预模糊图里（backdrop_host.dart）：卡片按位置裁那张图当底，
/// 自然只在底下太暗（深色是太亮）的地方变浓、别处照样透明；跨两块的卡片上下各是各的，拆成几截画的卡片拼接处也连续。
/// 磨砂再低也保底（正文 ≥ [bodyTarget]、次级字 ≥ 4.5），上限照旧 0.85。
abstract final class MeowScrimMap {
  /// 一格多大（dp）：遮罩每格一个像素，叠进模糊图时双线性放大
  static const cell = 8.0;

  /// 正文的对比度要求：磨砂 ≥ 0.5 是 7（同以前），往透明走降到 4.5（AA）为止，不再降到不保证
  static double bodyTarget(double frost) => 4.5 + 2.5 * MeowBackdrop.frostWeight(frost);

  /// 一格背后的颜色 [bg]：要垫多少（浅色垫白、深色垫黑），[texts]（颜色, 要求的对比度）才都够。
  /// 卡片的叠法同 [MeowBackdrop.scrimFor]：垫层在填充（[fillAlpha]）下面；浅色的 [cap] 是白的总覆盖率（含填充），
  /// 深色是黑垫层本身。二分到 1/1024，结果随背景连续变（不按 0.02 一档跳）。
  static double scrimAt(
    Color bg, {
    required double fillAlpha,
    required bool dark,
    required List<(Color, double)> texts,
    double cap = 0.85,
  }) {
    const white = Color(0xFFFFFFFF), black = Color(0xFF000000);
    Color surface(double s) => dark
        ? Color.alphaBlend(white.withValues(alpha: fillAlpha), Color.lerp(bg, black, s)!)
        : Color.lerp(bg, white, 1 - (1 - s) * (1 - fillAlpha))!;
    bool ok(double s) {
      final c = surface(s);
      return texts.every((t) => MeowTokens.contrast(t.$1, c) >= t.$2 - 1e-9);
    }

    if (ok(0)) return 0;
    final max = dark ? cap : (cap <= fillAlpha ? 0.0 : 1 - (1 - cap) / (1 - fillAlpha));
    if (max <= 0 || !ok(max)) return math.max(0, max);
    var lo = 0.0, hi = max;
    for (var i = 0; i < 10; i++) {
      final m = (lo + hi) / 2;
      if (ok(m)) {
        hi = m;
      } else {
        lo = m;
      }
    }
    return hi;
  }

  /// 每格一个像素的背景（RGBA，宽 [w] 高 [h]）→ 每格的垫层不透明度。每格再取周围 3×3 格里最大的：
  /// 一行字跨在两格之间、或贴着亮暗交界时也够（双线性放大会把格子之间抹平，这样不会抹到要求以下）
  static Float32List build(
    Uint8List rgba,
    int w,
    int h, {
    required double fillAlpha,
    required bool dark,
    required List<(Color, double)> texts,
    double cap = 0.85,
  }) {
    final raw = Float32List(w * h);
    final memo = <int, double>{};
    for (var i = 0; i < w * h; i++) {
      final key = (rgba[i * 4] << 16) | (rgba[i * 4 + 1] << 8) | rgba[i * 4 + 2];
      raw[i] = memo[key] ??= scrimAt(
        Color.fromARGB(255, rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]),
        fillAlpha: fillAlpha,
        dark: dark,
        texts: texts,
        cap: cap,
      );
    }
    final out = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var m = 0.0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            m = math.max(m, raw[yy * w + xx]);
          }
        }
        out[y * w + x] = m;
      }
    }
    return out;
  }

  /// 遮罩的像素：黑色 + 垫层不透明度（预乘与否都一样）；浅色叠的时候染成白（backdrop_host.dart）
  static Uint8List mask(Float32List scrim) {
    final out = Uint8List(scrim.length * 4);
    for (var i = 0; i < scrim.length; i++) {
      out[i * 4 + 3] = (scrim[i].clamp(0.0, 1.0) * 255).round();
    }
    return out;
  }
}

/// 把渲染好的背景交给页面底与玻璃卡片（宿主见 ../app/backdrop_host.dart；经典主题、还没渲染好时是 null）
class MeowBackdropScope extends InheritedWidget {
  const MeowBackdropScope({super.key, required this.images, required super.child});

  final MeowBackdropImages? images;

  static MeowBackdropImages? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MeowBackdropScope>()?.images;

  @override
  bool updateShouldNotify(MeowBackdropScope oldWidget) => !identical(images, oldWidget.images);
}
