import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app/glass_host.dart' show MeowGlassDevice;
import '../glass/liquid_glass.dart';
import '../state/ui_prefs.dart';
import 'motion.dart';
import 'tokens.dart';

/// 液态玻璃层（按用户要求：仅应用于 Dock 与弹出层，如气泡、弹出菜单与对话框；底层内容卡片保持清透实底）。
/// 背景由最外层的一个 [LiquidGlassHost] 每帧截一次、各块共用（宿主见 ../app/glass_host.dart），不给任何一块挂实时模糊。

/// 玻璃控件的尺寸与参数。
abstract final class MeowGlassMetrics {
  /// 底部卡片：离屏幕左右与底边各 8，圆角与屏幕圆角同心
  static const sheetInset = 8.0, sheetRadius = 38.0;

  /// 连接主卡：圆角加大到与屏幕圆角同心（宽屏窄列里小一号）
  static const heroRadius = 32.0, heroRadiusDense = 28.0;

  /// 按住玻璃按钮时鼓起一点（同 iOS），松手弹回
  static const pressScale = 1.06;
  static const pressDuration = Duration(milliseconds: 160);

  /// 「着色」相对「透明」：底色往不透明走剩余透明度的这个比例、模糊多这么多（iOS 26.1 的「着色」= 更厚、对比度更高）
  static const tintedOpacity = 0.5, tintedBlur = 6.0, tintedContrast = 1.5;

  /// 电源键玻璃的折射收小：按钮背后的色块与按钮一样大，照圆钮那一档（60 / 20）边缘会把主卡的底整条拉进来、盖住液面
  static const powerRefraction = 10.0, powerBevel = 8.0;

  /// 电源键玻璃外面那一层很淡的投影（不加光晕：用户明确不要）
  static const powerShadow = [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4))];

  /// 分段的玻璃滑块的投影
  static const lensShadow = [BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2))];

  /// 低端机：系统标为低内存设备，或物理内存低于这么多（MB）时，玻璃控件退回实色
  static const lowRamMb = 2560;
}

/// 玻璃控件开不开（由玻璃宿主给，见 ../app/glass_host.dart）。外层没有它 = 不开（测试、经典主题）。
class MeowGlassControls extends InheritedWidget {
  const MeowGlassControls({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MeowGlassControls>()?.enabled ?? false;

  @override
  bool updateShouldNotify(MeowGlassControls oldWidget) => enabled != oldWidget.enabled;
}

/// 这里的控件要不要画成玻璃：宿主允许（液态玻璃主题、不是低端机 / 高对比度）且外层确有玻璃宿主在取背景。
bool meowGlassOn(BuildContext context) => MeowGlassControls.of(context) && LiquidGlassScope.of(context);

/// 弹出菜单 / 锚定气泡 / 弹出对话框画不画成液态玻璃（同 iOS 27）：
/// 外层有玻璃宿主（手机，底栏那一套）就画，底层卡片不受影响；低端机退回实色。
bool meowPopupGlassOn(BuildContext context) => LiquidGlassScope.of(context) && !MeowGlassDevice.lowEnd;

/// 各弹出层的玻璃参数：按 iOS 27 主题、透明度滑杆（glassFrost）与透明/着色（glassTinted）动态调校。
abstract final class MeowGlassStyles {
  static const _light = ColorScheme.light(surfaceContainerHighest: Color(0xFFF3EDE6), surfaceBright: Color(0xFFFFFCFA));
  static const _dark = ColorScheme.dark(surfaceContainerHighest: Color(0xFF232530));

  static ColorScheme scheme(BuildContext context) => context.isDarkMode ? _dark : _light;

  /// 圆钮 / 胶囊：与 Dock 相同的清透光学折射 + 边缘高光（支持可选强调色着色，如节点页测速钮）
  static LiquidGlassStyle control(BuildContext context, {Color? accentTint}) {
    final prefs = MeowUiRuntime.current;
    final dark = context.isDarkMode;
    final frost = prefs.glassFrost.clamp(0.0, 1.0);
    final tinted = prefs.glassTinted;
    final blur = (2.2 + (frost - 0.5) * 3.0 + (tinted ? 2.0 : 0)).clamp(1.0, 8.0);
    final alpha = ((dark ? 0.30 : 0.24) + (tinted ? 0.16 : 0) + (frost - 0.5) * 0.12).clamp(0.16, 0.65);
    final baseTint = accentTint != null
        ? accentTint.withValues(alpha: (dark ? 0.38 : 0.32) + (tinted ? 0.14 : 0))
        : (dark ? const Color(0xFF1F222D) : const Color(0xFFFFFCFA)).withValues(alpha: alpha);
    return dark
        ? LiquidGlassStyle(
            tint: baseTint,
            contrast: -0.45,
            blur: blur,
            refraction: 80,
            bevel: 24,
            saturation: 1.9,
            rim: 0.56,
            rimWidth: 1.3,
            rimTail: 0.17,
            rimAdded: 0.46,
          )
        : LiquidGlassStyle(
            tint: baseTint,
            contrast: 0.45,
            blur: blur,
            refraction: 80,
            bevel: 24,
            saturation: 1.95,
            rim: 0.62,
            rimWidth: 1.3,
            rimTail: 0.17,
            rimAdded: 0.46,
            hairline: 0.32,
          );
  }

  /// 弹出菜单与对话框：丝滑柔雾光学玻璃——较高模糊消除背后杂乱文字斑块，保留精致边缘微折射与 1px 高光描边
  static LiquidGlassStyle menu(BuildContext context) {
    final prefs = MeowUiRuntime.current;
    final dark = context.isDarkMode;
    final frost = prefs.glassFrost.clamp(0.0, 1.0);
    final ios27 = prefs.isIos27Glass;
    final tinted = prefs.glassTinted;
    final alpha = ((dark ? 0.72 : 0.78) + (tinted ? 0.10 : 0) + (frost - 0.5) * 0.10).clamp(0.58, 0.90);
    final blur = ((ios27 ? 18.0 : 16.0) + (frost - 0.5) * 10.0 + (tinted ? 4.0 : 0)).clamp(10.0, 28.0);
    return LiquidGlassStyle(
      tint: (dark ? const Color(0xFF1A1D26) : const Color(0xFFFCFDFF)).withValues(alpha: alpha),
      contrast: 0,
      blur: blur,
      refraction: ios27 ? 24 : 16,
      bevel: ios27 ? 12 : 10,
      saturation: dark ? 1.45 : 1.5,
      brightness: dark ? 1.06 : 1.03,
      rim: ios27 ? (dark ? 0.44 : 0.52) : 0.30,
      rimWidth: 1.0,
      rimAdded: ios27 ? 0.30 : 0.18,
      hairline: dark ? 0.14 : 0.28,
    );
  }

  static LiquidGlassRim menuRim(BuildContext context) => LiquidGlassRim.menu(scheme(context));

  /// 锚在按钮上的气泡（自定义主页卡片、节点视图、选择代理组）：
  /// 奶油般均匀的高斯柔雾 + 温和边缘微折射 + 清晰玻璃高光边，既透出背后色彩氛围又不让底层文字糊成脏块干扰阅读。
  static LiquidGlassStyle popover(BuildContext context) {
    final prefs = MeowUiRuntime.current;
    final dark = context.isDarkMode;
    final frost = prefs.glassFrost.clamp(0.0, 1.0);
    final ios27 = prefs.isIos27Glass;
    final tinted = prefs.glassTinted;
    final alpha = ((dark ? 0.68 : 0.76) + (tinted ? 0.12 : 0) + (frost - 0.5) * 0.12).clamp(0.54, 0.88);
    final blur = ((ios27 ? 18.0 : 16.0) + (frost - 0.5) * 10.0 + (tinted ? 4.0 : 0)).clamp(12.0, 28.0);
    return dark
        ? LiquidGlassStyle(
            tint: const Color(0xFF1A1D27).withValues(alpha: alpha),
            contrast: 0,
            blur: blur,
            refraction: ios27 ? 26 : 18,
            bevel: ios27 ? 12 : 10,
            saturation: 1.5,
            brightness: 1.08,
            rim: ios27 ? 0.46 : 0.32,
            rimWidth: 1.0,
            rimAdded: ios27 ? 0.32 : 0.20,
            hairline: 0.16,
          )
        : LiquidGlassStyle(
            tint: const Color(0xFFFFFFFF).withValues(alpha: alpha),
            contrast: 0,
            blur: blur,
            refraction: ios27 ? 26 : 18,
            bevel: ios27 ? 12 : 10,
            saturation: 1.45,
            brightness: 1.04,
            rim: ios27 ? 0.54 : 0.36,
            rimWidth: 1.0,
            rimAdded: ios27 ? 0.32 : 0.20,
            hairline: 0.30,
          );
  }

  static List<BoxShadow> menuShadows(BuildContext context, [double depth = 1]) =>
      glassMenuShadows(scheme(context), depth);

  /// 电源键：圆钮那一档的玻璃（同 iOS 电源键的系统玻璃），折射收小。以前底下垫着墨色实心块，玻璃只着 5% 的白、颜色靠底透上来；
  /// 2026-10-28 去掉实心底之后（按钮别再是纯色）再那么薄，没连上时就只剩一圈边
  static LiquidGlassStyle power(BuildContext context) =>
      control(context).copyWith(refraction: MeowGlassMetrics.powerRefraction, bevel: MeowGlassMetrics.powerBevel);

  /// 分段的选中块：圆钮那一档的玻璃（白底带高光，同 iOS 分段的滑块）。底栏那块透明透镜（lens）放在一条匀色的槽上几乎看不出来
  static LiquidGlassStyle lens(BuildContext context) => control(context);
}

/// 圆角矩形的一块玻璃（圆角可以每帧变，如菜单从按钮变形出来）：[LiquidGlass] 只有胶囊和任意路径两种形状，
/// 任意路径每换一次形状要重算一遍折射轮廓，这里直接把圆角交给玻璃面板。[rim] = 菜单 / 卡片那一圈 iOS 的细边。
class MeowGlassBox extends SingleChildRenderObjectWidget {
  const MeowGlassBox({
    super.key,
    required this.style,
    required this.radius,
    this.rim,
    this.shadows = const [],
    this.outline,
    super.child,
  });

  final LiquidGlassStyle style;
  final BorderRadius radius;
  final LiquidGlassRim? rim;
  final List<BoxShadow> shadows;

  /// 不是圆角矩形时的外形（以盒子左上角为原点，如水滴变形里面板连着按钮那颗圆）；给了就不画 [rim] 与 [shadows]。
  final Path? outline;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeowGlassBox(style: style, radius: radius, rim: rim, shadows: shadows, outline: outline);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMeowGlassBox)
      ..style = style
      ..radius = radius
      ..rim = rim
      ..shadows = shadows
      ..outline = outline;
  }
}

class _RenderMeowGlassBox extends RenderProxyBox {
  _RenderMeowGlassBox({
    required LiquidGlassStyle style,
    required BorderRadius radius,
    required LiquidGlassRim? rim,
    required List<BoxShadow> shadows,
    required Path? outline,
  }) : _style = style,
       _radius = radius,
       _rim = rim,
       _shadows = shadows,
       _outline = outline;

  late final _pane = LiquidGlassPane(markNeedsPaint);

  LiquidGlassStyle _style;
  set style(LiquidGlassStyle v) {
    if (v == _style) return;
    _style = v;
    markNeedsPaint();
  }

  BorderRadius _radius;
  set radius(BorderRadius v) {
    if (v == _radius) return;
    _radius = v;
    markNeedsPaint();
  }

  LiquidGlassRim? _rim;
  set rim(LiquidGlassRim? v) {
    if (v == _rim) return;
    _rim = v;
    markNeedsPaint();
  }

  List<BoxShadow> _shadows;
  set shadows(List<BoxShadow> v) {
    if (identical(v, _shadows)) return;
    _shadows = v;
    markNeedsPaint();
  }

  Path? _outline;
  set outline(Path? v) {
    if (identical(v, _outline)) return;
    _outline = v;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void dispose() {
    _pane.dispose();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      _pane.clear();
    } else {
      final rect = offset & size;
      final outline = _outline;
      if (outline != null) {
        _pane.paint(context, rect, shape: LiquidGlassOutline(outline), style: _style);
      } else {
        _pane.paint(context, rect, shape: LiquidGlassCorners(_radius), style: _style, shadows: _shadows, rim: _rim);
        // 细边画在玻璃外面（玻璃面板自己画内侧的高光）
        _rim?.paintLine(context.canvas, rect, _radius.topLeft.x);
      }
    }
    super.paint(context, offset);
  }
}

/// 玻璃圆钮 / 胶囊（页面右上角的操作钮、「高级设置」这类）：按住时玻璃从手指处亮起、整颗鼓起一点，松手弹回。
/// 形状随尺寸：正方形是圆，长条是胶囊。[child] 自己定尺寸；[onTap] 为 null = 不可用（只把内容调淡，不给整块玻璃加透明度——
/// 半透明会把它变成离屏层，玻璃就读不到背后的画面了）。
class MeowGlassButton extends StatefulWidget {
  const MeowGlassButton({
    super.key,
    required this.child,
    required this.onTap,
    this.tooltip,
    this.style,
    this.shadows = defaultShadows,
  });

  static const defaultShadows = [BoxShadow(color: Color(0x18000000), blurRadius: 16, offset: Offset(0, 4))];

  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  final LiquidGlassStyle? style;
  final List<BoxShadow> shadows;

  @override
  State<MeowGlassButton> createState() => _MeowGlassButtonState();
}

class _MeowGlassButtonState extends State<MeowGlassButton> {
  bool _down = false;

  void _press(bool down) {
    if (_down != down && mounted) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget body = LiquidGlass(
      style: widget.style ?? MeowGlassStyles.control(context),
      shadows: widget.shadows,
      pressed: _down,
      child: Opacity(opacity: enabled ? 1 : 0.4, child: widget.child),
    );
    body = AnimatedScale(
      scale: _down ? MeowGlassMetrics.pressScale : 1,
      duration: MeowMotion.of(context, MeowGlassMetrics.pressDuration),
      curve: Curves.easeOut,
      child: body,
    );
    body = Semantics(
      button: true,
      enabled: enabled,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => _press(true) : null,
          onTapUp: enabled ? (_) => _press(false) : null,
          onTapCancel: enabled ? () => _press(false) : null,
          onTap: widget.onTap,
          child: body,
        ),
      ),
    );
    return widget.tooltip == null ? body : Tooltip(message: widget.tooltip!, child: body);
  }
}
