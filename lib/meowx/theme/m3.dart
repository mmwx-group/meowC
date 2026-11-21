import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import '../state/ui_prefs.dart';

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

  /// 按种子色与主题预设生成一份精修色板：去掉深色下默认 tonalSpot 发闷发褐的底色，
  /// 统一柔化错误容器（超时胶囊不再刺眼纯红），让底面、卡片与次级槽层次分明。
  static ColorScheme scheme(
    Color seed,
    Brightness brightness, {
    MeowVisualPreset preset = MeowVisualPreset.crispMist,
  }) {
    final effectiveSeed = switch (preset) {
      MeowVisualPreset.obsidian => const Color(0xFF10B981),
      MeowVisualPreset.morandiMist => const Color(0xFF5D8A78),
      _ => seed,
    };
    final base = ColorScheme.fromSeed(
      seedColor: effectiveSeed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    final dark = brightness == Brightness.dark;
    // 柔化 errorContainer：超时胶囊用低饱和柔红底 + 清晰亮红字，不再出现刺眼纯红块
    final errorContainer = dark ? const Color(0xFF3A1A22) : const Color(0xFFFCE8EC);
    final onErrorContainer = dark ? const Color(0xFFFF8FA3) : const Color(0xFFB4233C);

    return switch (preset) {
      MeowVisualPreset.crispMist || MeowVisualPreset.ios27Glass => dark
          ? base.copyWith(
              surface: preset == MeowVisualPreset.ios27Glass ? const Color(0xFF0E1015) : const Color(0xFF101114),
              surfaceContainerLowest: const Color(0xFF14161A),
              surfaceContainerLow: const Color(0xFF17191E),
              surfaceContainer: const Color(0xFF1A1C22),
              surfaceContainerHigh: const Color(0xFF1C1E24),
              surfaceContainerHighest: const Color(0xFF252831),
              outlineVariant: const Color(0xFF2E313C),
              outline: const Color(0xFF5A5F70),
              onSurface: const Color(0xFFF3F4F7),
              onSurfaceVariant: const Color(0xFF9EA4B2),
              inverseSurface: const Color(0xFF2E323D),
              onInverseSurface: const Color(0xFFF5F6FA),
              errorContainer: errorContainer,
              onErrorContainer: onErrorContainer,
            )
          : base.copyWith(
              surface: preset == MeowVisualPreset.ios27Glass ? const Color(0xFFF2F5FA) : const Color(0xFFF4F5F8),
              surfaceContainerLowest: const Color(0xFFFFFFFF),
              surfaceContainerLow: const Color(0xFFFAFBFD),
              surfaceContainer: const Color(0xFFFFFFFF),
              surfaceContainerHigh: const Color(0xFFF0F2F6),
              surfaceContainerHighest: const Color(0xFFE7EAF0),
              outlineVariant: const Color(0xFFE2E6EE),
              outline: const Color(0xFFB8BFCC),
              onSurface: const Color(0xFF14161B),
              onSurfaceVariant: const Color(0xFF616876),
              errorContainer: errorContainer,
              onErrorContainer: onErrorContainer,
            ),
      MeowVisualPreset.obsidian => dark
          ? base.copyWith(
              surface: const Color(0xFF07080A),
              surfaceContainerLowest: const Color(0xFF0C0E12),
              surfaceContainerLow: const Color(0xFF111318),
              surfaceContainer: const Color(0xFF14171D),
              surfaceContainerHigh: const Color(0xFF15181F),
              surfaceContainerHighest: const Color(0xFF1F242E),
              primary: const Color(0xFF34D399),
              onPrimary: const Color(0xFF052E20),
              primaryContainer: const Color(0xFF0F2D24),
              onPrimaryContainer: const Color(0xFFA7F3D0),
              secondaryContainer: const Color(0xFF18242B),
              onSecondaryContainer: const Color(0xFFBAE6FD),
              tertiary: const Color(0xFF38BDF8),
              tertiaryContainer: const Color(0xFF132635),
              onTertiaryContainer: const Color(0xFFBAE6FD),
              outlineVariant: const Color(0xFF242A36),
              onSurface: const Color(0xFFF1F5F9),
              onSurfaceVariant: const Color(0xFF94A3B8),
              inverseSurface: const Color(0xFF252D3B),
              onInverseSurface: const Color(0xFFF1F5F9),
              errorContainer: errorContainer,
              onErrorContainer: onErrorContainer,
            )
          : base.copyWith(
              surface: const Color(0xFFF1F4F7),
              surfaceContainer: const Color(0xFFFFFFFF),
              surfaceContainerHigh: const Color(0xFFE9EEF4),
              surfaceContainerHighest: const Color(0xFFDEE5EE),
              outlineVariant: const Color(0xFFD9E1EB),
              errorContainer: errorContainer,
              onErrorContainer: onErrorContainer,
            ),
      MeowVisualPreset.sakuraAura => dark
          ? base.copyWith(
              surface: const Color(0xFF131019),
              surfaceContainerLowest: const Color(0xFF181420),
              surfaceContainerLow: const Color(0xFF1C1726),
              surfaceContainer: const Color(0xFF1F1A2A),
              surfaceContainerHigh: const Color(0xFF221C2E),
              surfaceContainerHighest: const Color(0xFF2D253B),
              outlineVariant: const Color(0xFF382F4A),
              onSurface: const Color(0xFFF6F1F8),
              onSurfaceVariant: const Color(0xFFB0A4BC),
              inverseSurface: const Color(0xFF382D47),
              onInverseSurface: const Color(0xFFFBF7FC),
              errorContainer: errorContainer,
              onErrorContainer: onErrorContainer,
            )
          : base.copyWith(
              surface: const Color(0xFFFAF3F7),
              surfaceContainer: const Color(0xFFFFFFFF),
              surfaceContainerHigh: const Color(0xFFF4EAF0),
              surfaceContainerHighest: const Color(0xFFECE0E8),
              outlineVariant: const Color(0xFFEADCE4),
              errorContainer: errorContainer,
              onErrorContainer: onErrorContainer,
            ),
      MeowVisualPreset.morandiMist => dark
          ? base.copyWith(
              surface: const Color(0xFF111413),
              surfaceContainerLowest: const Color(0xFF161918),
              surfaceContainerLow: const Color(0xFF191D1B),
              surfaceContainer: const Color(0xFF1C201E),
              surfaceContainerHigh: const Color(0xFF1E2321),
              surfaceContainerHighest: const Color(0xFF272D2A),
              outlineVariant: const Color(0xFF323936),
              onSurface: const Color(0xFFEDF1EE),
              onSurfaceVariant: const Color(0xFF9BA6A0),
              inverseSurface: const Color(0xFF2D3532),
              onInverseSurface: const Color(0xFFF1F5F2),
              errorContainer: errorContainer,
              onErrorContainer: onErrorContainer,
            )
          : base.copyWith(
              surface: const Color(0xFFF2F3F0),
              surfaceContainer: const Color(0xFFFFFFFF),
              surfaceContainerHigh: const Color(0xFFE9ECE8),
              surfaceContainerHighest: const Color(0xFFDFE3DE),
              outlineVariant: const Color(0xFFDDE1DC),
              errorContainer: errorContainer,
              onErrorContainer: onErrorContainer,
            ),
    };
  }
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

/// 卡片底色与极细描边：深浅色都保持清透实底 + 0.8px 细描边，层次分明。
extension MeowCardColors on ColorScheme {
  bool get _dark => brightness == Brightness.dark;
  Color get card => _dark ? surfaceContainerHigh : surfaceContainer;
  Color get cardInner => _dark ? surfaceContainerHighest : surfaceContainerHigh;
  Color get cardBorder => outlineVariant.withValues(alpha: _dark ? 0.55 : 0.7);
}

extension MeowM3Context on BuildContext {
  ColorScheme get cs => Theme.of(this).colorScheme;
  MeowM3 get m3 => Theme.of(this).extension<MeowM3>() ?? MeowM3.from(Theme.of(this).colorScheme);
  TextTheme get tt => Theme.of(this).textTheme;
}
