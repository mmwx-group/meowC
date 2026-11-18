import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// Material 3 Expressive 的底子：色板、语义色、形状与弹簧（2026-11，见 design/m3-expressive/PLAN.md）。
///
/// 颜色一律从 [ColorScheme] 取（`context.cs`），色板以外的语义色（通 / 慢 / 超时这类状态）从 [MeowM3] 取（`context.m3`），
/// 都跟着种子色与深浅色变。旧的 `context.mm`（MeowTokens）在改版过渡期由同一份色板推出来，新写的代码不再用它。
abstract final class MeowColors {
  /// 品牌玫瑰（`MeowSettings.accentColor` 的缺省值）
  static const brandSeed = Color(0xFFB02E63);

  /// 「主题色」的预设（外观页一排色块）；预设以外的是自定义取色
  static const presets = <(String, int)>[
    ('玫瑰', 0xFFB02E63),
    ('樱桃', 0xFFC0392B),
    ('橘子', 0xFFD9772B),
    ('柠檬', 0xFFB59A1F),
    ('薄荷', 0xFF2E8B6E),
    ('海洋', 0xFF2D6FB0),
    ('薰衣草', 0xFF6E5BA8),
    ('石墨', 0xFF5F6368),
  ];

  static String? nameOf(int color) => presets.where((p) => p.$2 == color).firstOrNull?.$1;

  /// 按种子色生成一份色板（tonal spot：系统「跟随桌布」也是这一种）
  static ColorScheme scheme(Color seed, Brightness brightness) => ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  );
}

/// 色板以外的语义色：通（绿）/ 慢（琥珀）/ 第三种状态色（青），各带 container 与上面的字色。
/// 色相固定，按种子色轻轻调和（`Blend.harmonize`），所以换主题色时它们也跟着偏一点、不显得突兀。
/// 超时 / 失败直接用 [ColorScheme.error] 那一组。
@immutable
class MeowM3 extends ThemeExtension<MeowM3> {
  const MeowM3({
    required this.ok,
    required this.onOk,
    required this.okContainer,
    required this.onOkContainer,
    required this.warn,
    required this.onWarn,
    required this.warnContainer,
    required this.onWarnContainer,
    required this.info,
    required this.infoContainer,
    required this.onInfoContainer,
  });

  final Color ok, onOk, okContainer, onOkContainer;
  final Color warn, onWarn, warnContainer, onWarnContainer;
  final Color info, infoContainer, onInfoContainer;

  static const _okHue = Color(0xFF2E9E5B), _warnHue = Color(0xFFE08A1E), _infoHue = Color(0xFF1E8FA6);

  factory MeowM3.from(ColorScheme cs) {
    final dark = cs.brightness == Brightness.dark;
    ({Color c, Color on, Color container, Color onContainer}) roles(Color hue) {
      final harmonized = Color(Blend.harmonize(hue.toARGB32(), cs.primary.toARGB32()));
      final p = TonalPalette.of(Hct.fromInt(harmonized.toARGB32()).hue, 48);
      Color t(int tone) => Color(p.get(tone));
      return dark
          ? (c: t(80), on: t(20), container: t(30), onContainer: t(90))
          : (c: t(40), on: t(100), container: t(90), onContainer: t(30));
    }

    final ok = roles(_okHue), warn = roles(_warnHue), info = roles(_infoHue);
    return MeowM3(
      ok: ok.c,
      onOk: ok.on,
      okContainer: ok.container,
      onOkContainer: ok.onContainer,
      warn: warn.c,
      onWarn: warn.on,
      warnContainer: warn.container,
      onWarnContainer: warn.onContainer,
      info: info.c,
      infoContainer: info.container,
      onInfoContainer: info.onContainer,
    );
  }

  @override
  MeowM3 copyWith() => this;

  @override
  MeowM3 lerp(MeowM3? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return MeowM3(
      ok: l(ok, other.ok),
      onOk: l(onOk, other.onOk),
      okContainer: l(okContainer, other.okContainer),
      onOkContainer: l(onOkContainer, other.onOkContainer),
      warn: l(warn, other.warn),
      onWarn: l(onWarn, other.onWarn),
      warnContainer: l(warnContainer, other.warnContainer),
      onWarnContainer: l(onWarnContainer, other.onWarnContainer),
      info: l(info, other.info),
      infoContainer: l(infoContainer, other.infoContainer),
      onInfoContainer: l(onInfoContainer, other.onInfoContainer),
    );
  }
}

/// M3 Expressive 的圆角档（dp）。卡片 / 主卡用 [xl] / [xlInc]，分段清单的首尾用 [l] 起、中间 [xs]，胶囊用 [full]。
abstract final class MeowShape {
  static const none = 0.0;
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const lInc = 20.0;
  static const xl = 28.0;
  static const xlInc = 32.0;
  static const xxl = 48.0;
  static const full = 999.0;

  /// 分段清单（一组连着的行）第 [index] / [count] 行的圆角：首尾 [outer]、中间 [inner]
  static BorderRadius segment(int index, int count, {double outer = lInc, double inner = xs}) {
    final top = index == 0 ? outer : inner, bottom = index == count - 1 ? outer : inner;
    return BorderRadius.vertical(top: Radius.circular(top), bottom: Radius.circular(bottom));
  }
}

/// M3 Expressive 的弹簧（Material 的 motion spec：空间 = 位置 / 尺寸 / 形状，带一点回弹；效果 = 颜色 / 透明度，不回弹）。
/// stiffness / damping ratio 换成 Flutter 的 SpringDescription（质量 1）。
abstract final class MeowSprings {
  static SpringDescription _s(double stiffness, double ratio) =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: stiffness, ratio: ratio);

  static final spatialFast = _s(1400, 0.9);
  static final spatialDefault = _s(700, 0.9);
  static final spatialSlow = _s(300, 0.9);
  static final effectsFast = _s(3800, 1);
  static final effectsDefault = _s(1600, 1);
  static final effectsSlow = _s(800, 1);

  /// 形状变化（按钮组选中变胶囊、节点选中）这类短动画用的曲线与时长：近似 spatialFast 的回弹
  static const shapeCurve = Cubic(0.34, 1.36, 0.64, 1);
  static const shapeDuration = Duration(milliseconds: 350);
  static const effectsCurve = Cubic(0.31, 0.94, 0.34, 1);
  static const effectsDuration = Duration(milliseconds: 200);
}

/// 卡片底色：M3 默认的 surfaceContainerLow 和页面底（surface）太接近，深色下几乎分不出（用户反馈「卡片和背景色糊在一起」），
/// 统一加深一级：浅色 surfaceContainer、深色 surfaceContainerHigh；卡片里的次级块（[cardInner]）再深一级。
extension MeowCardColors on ColorScheme {
  bool get _dark => brightness == Brightness.dark;
  Color get card => _dark ? surfaceContainerHigh : surfaceContainer;
  Color get cardInner => _dark ? surfaceContainerHighest : surfaceContainerHigh;
}

extension MeowM3Context on BuildContext {
  ColorScheme get cs => Theme.of(this).colorScheme;
  MeowM3 get m3 => Theme.of(this).extension<MeowM3>() ?? MeowM3.from(Theme.of(this).colorScheme);
  TextTheme get tt => Theme.of(this).textTheme;
}
