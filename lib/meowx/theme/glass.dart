import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../glass/liquid_glass.dart';
import 'motion.dart';
import 'tokens.dart';

/// 液态玻璃主题的控件层（照 iOS 26 官方 App：玻璃只用在浮在内容上面的控件——右上角圆钮 / 胶囊、弹出菜单、底部卡片、
/// 电源键、首页模式分段的滑块；内容卡片保持实色）。玻璃本身是 ../glass/liquid_glass.dart（移植自 FlClash 0.9.1），
/// 背景由最外层的一个 [LiquidGlassHost] 每帧截一次、各块共用（宿主见 ../app/glass_host.dart），这里不给任何一块挂实时模糊。
///
/// 画不画玻璃一律问 [meowGlassOn]：液态玻璃主题、外层有玻璃宿主、不是低端机 / 系统没开高对比度（「减弱透明度」的同类）。
/// 不画时各控件照经典主题的实色画法，所以经典主题下不多出任何合成层。

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

  /// 电源键的玻璃几乎不着色：背后的卡片与半透明的樱粉液面透上来（液态玻璃主题下没有墨色底），玻璃只给边缘的折射与高光（「着色」稍厚一点）。
  /// 折射收小：按钮背后的色块与按钮一样大，照圆钮那一档（60 / 20）边缘会把主卡的浅底整条拉进来，盖住墨色
  static const powerTint = 0.05, powerTintTinted = 0.14;
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

/// 各控件的玻璃参数：FlClash 的几档（regular / menu / tinted / lens）按「透明 / 着色」调厚薄。
/// 玻璃不跟卡片颜色变：取色用固定的一份配色，不读主题里随卡片色变的 surface。
abstract final class MeowGlassStyles {
  static const _light = ColorScheme.light(surfaceContainerHighest: Color(0xFFF3EDE6), surfaceBright: Color(0xFFFFFCFA));
  static const _dark = ColorScheme.dark(surfaceContainerHighest: Color(0xFF2F2838));

  static ColorScheme scheme(BuildContext context) => context.isDarkMode ? _dark : _light;

  /// 「着色」：底色更不透明、模糊更大、对比度更高；「透明」原样
  static LiquidGlassStyle tune(LiquidGlassStyle style, bool tinted) => !tinted
      ? style
      : style.copyWith(
          tint: style.tint.withValues(alpha: style.tint.a + (1 - style.tint.a) * MeowGlassMetrics.tintedOpacity),
          blur: style.blur + MeowGlassMetrics.tintedBlur,
          contrast: style.contrast * MeowGlassMetrics.tintedContrast,
        );

  /// 圆钮 / 胶囊
  static LiquidGlassStyle control(BuildContext context) =>
      tune(LiquidGlassStyle.regular(scheme(context)), context.mm.glassTinted);

  /// 弹出菜单与底部卡片：比圆钮更厚（上面是成段的字）
  static LiquidGlassStyle menu(BuildContext context) =>
      tune(LiquidGlassStyle.menu(scheme(context)), context.mm.glassTinted);

  static LiquidGlassRim menuRim(BuildContext context) => LiquidGlassRim.menu(scheme(context));

  static List<BoxShadow> menuShadows(BuildContext context, [double depth = 1]) =>
      glassMenuShadows(scheme(context), depth);

  /// 电源键：樱粉着色那一档的边缘与高光，底色几乎透明（颜色来自背后的卡片与液面）
  static LiquidGlassStyle power(BuildContext context) {
    final mm = context.mm;
    return LiquidGlassStyle.tinted(scheme(context), mm.btnOn).copyWith(
      tint: Colors.white.withValues(alpha: mm.glassTinted ? MeowGlassMetrics.powerTintTinted : MeowGlassMetrics.powerTint),
      refraction: MeowGlassMetrics.powerRefraction,
      bevel: MeowGlassMetrics.powerBevel,
    );
  }

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
    super.child,
  });

  final LiquidGlassStyle style;
  final BorderRadius radius;
  final LiquidGlassRim? rim;
  final List<BoxShadow> shadows;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeowGlassBox(style: style, radius: radius, rim: rim, shadows: shadows);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMeowGlassBox)
      ..style = style
      ..radius = radius
      ..rim = rim
      ..shadows = shadows;
  }
}

class _RenderMeowGlassBox extends RenderProxyBox {
  _RenderMeowGlassBox({
    required LiquidGlassStyle style,
    required BorderRadius radius,
    required LiquidGlassRim? rim,
    required List<BoxShadow> shadows,
  }) : _style = style,
       _radius = radius,
       _rim = rim,
       _shadows = shadows;

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
      _pane.paint(context, rect, shape: LiquidGlassCorners(_radius), style: _style, shadows: _shadows, rim: _rim);
      // 细边画在玻璃外面（玻璃面板自己画内侧的高光）
      _rim?.paintLine(context.canvas, rect, _radius.topLeft.x);
    }
    super.paint(context, offset);
  }
}

/// 玻璃圆钮 / 胶囊（页面右上角的操作钮、「高级设置」这类）：按住时玻璃从手指处亮起、整颗鼓起一点，松手弹回。
/// 形状随尺寸：正方形是圆，长条是胶囊。[child] 自己定尺寸；[onTap] 为 null = 不可用（只把内容调淡，不给整块玻璃加透明度——
/// 半透明会把它变成离屏层，玻璃就读不到背后的画面了）。
class MeowGlassButton extends StatefulWidget {
  const MeowGlassButton({super.key, required this.child, required this.onTap, this.tooltip});

  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;

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
      style: MeowGlassStyles.control(context),
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
