import 'dart:io';

import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_icon.dart';
import '../../state/meow_settings.dart';
import '../../theme/button_fill.dart';
import '../../theme/card_surface.dart';
import '../../theme/color_picker.dart';
import '../../theme/glass_art.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import 'me_kit.dart';

/// 「我的 › 外观」里主题风格 / 玻璃样式 / 卡片颜色 / 启动卡片颜色 / 强调色 / App 图标几行（[AppearanceRows] 用；手机在底部卡片里，宽屏铺在「外观 · 关于」分组里）。

void _update(WidgetRef ref, MeowSettings Function(MeowSettings s) f) =>
    ref.read(meowSettingProvider.notifier).updateState(f);

/// 一行的骨架：标题（+ 右侧小字）在上，控件在下（这几项的控件都比一行宽，不放行尾）。
class _StackedRow extends StatelessWidget {
  const _StackedRow({required this.label, this.value, required this.child, this.caption});

  final String label;
  final String? value;
  final Widget child;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final dense = MeDense.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(14, dense ? 8 : 12, 12, dense ? 10 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: dense ? MeowFont.footnote : MeowFont.subheadline,
                  fontWeight: FontWeight.w500,
                  color: mm.t1,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value ?? '',
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: dense ? MeowFont.caption : MeowFont.footnote, color: mm.t2),
                ),
              ),
            ],
          ),
          SizedBox(height: dense ? 8 : 10),
          child,
          if (caption != null) ...[
            const SizedBox(height: 8),
            Text(caption!, style: TextStyle(fontSize: dense ? MeowFont.caption2 : MeowFont.caption, color: mm.t2)),
          ],
        ],
      ),
    );
  }
}

/// 主题风格：经典 / 液态玻璃两张小缩略图（选中 = 玫红描边 + 淡粉底）。
class ThemeStyleRow extends ConsumerWidget {
  const ThemeStyleRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(meowSettingProvider.select((s) => s.themeStyle));
    return _StackedRow(
      label: '主题风格',
      child: Row(
        children: [
          for (final (i, v) in MeowThemeStyle.values.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _StyleChoice(
                style: v,
                selected: v == style,
                onTap: () => _update(ref, (s) => s.copyWith(themeStyle: v)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StyleChoice extends StatelessWidget {
  const _StyleChoice({required this.style, required this.selected, required this.onTap});

  final MeowThemeStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final dense = MeDense.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: style.label,
      excludeSemantics: true,
      child: Material(
        color: selected ? mm.buttonFill(MeowButtonFill.accent) : mm.card2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? mm.accent : Colors.transparent, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                SizedBox(height: dense ? 48 : 64, child: _StyleThumb(glass: style == MeowThemeStyle.glass)),
                const SizedBox(height: 6),
                Text(
                  style.label,
                  style: TextStyle(
                    fontSize: MeowFont.caption,
                    fontWeight: FontWeight.w700,
                    color: selected ? mm.accent : mm.t1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 缩略图（设计稿同款）：页面底 + 主卡 + 一张卡片 + 底栏胶囊；液态玻璃那张的主卡与卡片一样是玻璃（全部卡片一致），底栏是带高光的半透明玻璃。
/// 只是示意图：用普通的半透明与描边画，不放真玻璃（设置页不多出玻璃层）。
class _StyleThumb extends StatelessWidget {
  const _StyleThumb({required this.glass});

  final bool glass;

  @override
  Widget build(BuildContext context) {
    final dark = context.isDarkMode;
    final base = dark ? MeowTokens.dark : MeowTokens.light;
    final spec = MeowGlassSpec.of(dark);
    final shades = MeowTokens.glassShades(const Color(MeowCardColors.white), dark: dark);
    final bg = glass ? spec.bg : base.bg;
    // 液态玻璃那张的卡片也是半透明的玻璃（白卡 + 亮边）
    final card = glass ? shades.card : base.elev;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: bg,
        child: Stack(
          children: [
            Positioned(
              left: 8,
              right: 8,
              top: 8,
              height: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: glass ? card : base.hero,
                  borderRadius: BorderRadius.circular(5),
                  border: glass ? Border.all(color: shades.rim, width: 0.8) : null,
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              top: 28,
              height: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: card,
                  borderRadius: BorderRadius.circular(5),
                  border: glass ? Border.all(color: shades.rim, width: 0.8) : null,
                ),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 6,
              height: 14,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: glass ? Colors.white.withValues(alpha: dark ? 0.12 : 0.3) : card,
                  borderRadius: BorderRadius.circular(7),
                  border: glass ? Border.all(color: Colors.white.withValues(alpha: dark ? 0.25 : 0.7), width: 0.8) : null,
                  boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 6, offset: Offset(0, 2))],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// App 图标（只 Android）：默认（猫娘）/ M · 深色 / M · 浅色三张圆角缩略图，选中样式同主题风格。
class AppIconRow extends ConsumerWidget {
  const AppIconRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appIconProvider).valueOrNull;
    return _StackedRow(
      label: 'App 图标',
      caption: _appIconCaption,
      child: Row(
        children: [
          for (final (i, v) in MeowAppIcon.values.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _AppIconChoice(
                icon: v,
                selected: v == current,
                onTap: () => ref.read(appIconProvider.notifier).select(v),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// 实测（Android 15 模拟器 + Pixel Launcher）：每次切换系统都会立刻收起 App 界面（启动它的那个入口被停用），进程与连接不受影响，
// 重新打开回到原来的页面；主屏幕上的图标原地换新。别的桌面可能把旧图标移走
const _appIconCaption = '切换时系统会收起 App 界面（连接不受影响），从桌面重新打开即可；有的桌面会把主屏幕上的旧图标移走，从应用列表重新拖出来。';

class _AppIconChoice extends StatelessWidget {
  const _AppIconChoice({required this.icon, required this.selected, required this.onTap});

  final MeowAppIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final dense = MeDense.of(context);
    final side = dense ? 44.0 : 56.0;
    return Semantics(
      button: true,
      selected: selected,
      label: icon.label,
      excludeSemantics: true,
      child: Material(
        color: selected ? mm.buttonFill(MeowButtonFill.accent) : mm.card2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? mm.accent : Colors.transparent, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                // 圆角画在图里；256px 的图按显示尺寸解码
                Image.asset(
                  icon.preview,
                  width: side,
                  height: side,
                  cacheWidth: (side * MediaQuery.devicePixelRatioOf(context)).round(),
                  filterQuality: FilterQuality.medium,
                ),
                const SizedBox(height: 6),
                Text(
                  icon.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: MeowFont.caption,
                    fontWeight: FontWeight.w700,
                    color: selected ? mm.accent : mm.t1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 液态玻璃的背景：平涂 / 光斑 / 插画 三选一（缺省光斑）。颜色仍来自「底色」。
class GlassPatternRow extends ConsumerWidget {
  const GlassPatternRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pattern = ref.watch(meowSettingProvider.select((s) => s.bgPattern));
    final dense = MeDense.of(context);
    return _StackedRow(
      label: '背景',
      caption: switch (pattern) {
        MeowBgPattern.flat => '只有底色，卡片照样磨砂（底下没有东西可模糊）。',
        MeowBgPattern.blobs => '底色化成几团大光斑铺在整屏，卡片透出模糊后的光斑。',
        MeowBgPattern.art => '自己选的图片铺满整屏、压一层底色，卡片透出模糊后的图片；磨砂调低时那层底色跟着变淡。还没选图时先按光斑画。',
      },
      child: MeowSegment<MeowBgPattern>(
        items: [for (final v in MeowBgPattern.values) (v, v.label)],
        value: pattern,
        onCard: true,
        height: dense ? 32 : 38,
        fontSize: dense ? 12 : 13,
        onChanged: (v) => _update(ref, (s) => s.copyWith(bgPattern: v)),
      ),
    );
  }
}

/// 插画背景用的图片（背景选了插画才出现）：缩略图 + 选择 / 更换。安卓从系统相册选（不要存储权限），Windows 选文件；
/// 同一时间只存一张（见 [MeowGlassArt]）。
class GlassArtRow extends ConsumerStatefulWidget {
  const GlassArtRow({super.key});

  @override
  ConsumerState<GlassArtRow> createState() => _GlassArtRowState();
}

class _GlassArtRowState extends ConsumerState<GlassArtRow> {
  bool _busy = false;
  String? _fileId;
  Future<File>? _file;

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final id = await MeowGlassArt.pick();
      if (id != null) _update(ref, (s) => s.copyWith(glassArtImage: id));
    } catch (e) {
      globalState.showNotifier(e is MeowGlassArtError ? e.message : '选择图片失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final id = ref.watch(meowSettingProvider.select((s) => s.glassArtImage));
    if (id != _fileId) {
      _fileId = id;
      _file = id == null ? null : MeowGlassArt.file(id);
    }
    final dense = MeDense.of(context);
    final side = dense ? 48.0 : 56.0;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return _StackedRow(
      label: '插画图片',
      value: id == null ? '未选择' : null,
      caption: id == null ? '选一张自己的图片铺在背景上。' : null,
      child: Row(
        children: [
          if (_file != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox.square(
                  dimension: side,
                  child: FutureBuilder<File>(
                    future: _file,
                    builder: (_, snap) => snap.data == null
                        ? ColoredBox(color: mm.card2)
                        // 只按缩略图的大小解码
                        : Image.file(
                            snap.data!,
                            fit: BoxFit.cover,
                            cacheWidth: (side * dpr).round(),
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => ColoredBox(color: mm.card2),
                          ),
                  ),
                ),
              ),
            ),
          const Spacer(),
          MePill(label: _busy ? '正在读取…' : (id == null ? '选择图片' : '更换图片'), height: dense ? 34 : 38, onTap: _busy ? null : _pick),
        ],
      ),
    );
  }
}

/// 卡片的磨砂强度（0 透明 – 1 厚，缺省 0.5）：拖动时只改这一行的数，松手才存（存了才重画背景与主题）。
class GlassFrostRow extends ConsumerStatefulWidget {
  const GlassFrostRow({super.key});

  @override
  ConsumerState<GlassFrostRow> createState() => _GlassFrostRowState();
}

class _GlassFrostRowState extends ConsumerState<GlassFrostRow> {
  double? _dragging;

  static String _label(double v) => v < 0.05 ? '透明' : (v < 0.34 ? '通透' : (v < 0.67 ? '适中' : '厚'));

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final saved = ref.watch(meowSettingProvider.select((s) => s.glassFrost));
    final value = (_dragging ?? saved).clamp(0.0, 1.0);
    return _StackedRow(
      label: '磨砂强度',
      value: '${_label(value)} · ${(value * 100).round()}%',
      caption: '越往右卡片越厚、背后越模糊，字看不清时会自动加厚；拉到最左是透明玻璃，不再自动加厚，插画背景上的罩色也一起去掉。',
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: mm.accent,
          inactiveTrackColor: mm.card2,
          thumbColor: mm.accent,
          overlayColor: mm.accent.withValues(alpha: 0.12),
          trackHeight: 4,
        ),
        child: Slider(
          value: value,
          onChanged: (v) => setState(() => _dragging = v),
          onChangeEnd: (v) {
            _update(ref, (s) => s.copyWith(glassFrost: v));
            setState(() => _dragging = null);
          },
        ),
      ),
    );
  }
}

/// 玻璃样式：透明 / 着色（只在液态玻璃下出现）。
class GlassTintRow extends ConsumerWidget {
  const GlassTintRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tint = ref.watch(meowSettingProvider.select((s) => s.glassTint));
    final dense = MeDense.of(context);
    return _StackedRow(
      label: '玻璃样式',
      caption: '透明更通透；着色更不透明、对比度更高（同 iOS 26.1 的系统选项）。',
      child: MeowSegment<MeowGlassTint>(
        items: [for (final v in MeowGlassTint.values) (v, v.label)],
        value: tint,
        onCard: true,
        height: dense ? 32 : 38,
        fontSize: dense ? 12 : 13,
        onChanged: (v) => _update(ref, (s) => s.copyWith(glassTint: v)),
      ),
    );
  }
}

/// 三种可调颜色（卡片 / 启动卡片 / 强调色）：行的标题、预设、说明、取色页的标题与预览、存到哪个字段。
/// 液态玻璃主题下「卡片颜色」改叫「底色」（存的仍是 cardColor）：铺成整页的底，内容卡片变成玻璃（见 [MeowTokens.glassShades]）。
enum MeowColorKind {
  card('卡片颜色', '自定义卡片颜色', '只改内容卡片，玻璃控件不变；深色下取同色相的深色卡片。'),
  hero('启动卡片颜色', '自定义启动卡片颜色', '首页连接主卡与电源键；深色下取同色相的深色。'),
  accent('强调色', '自定义强调色', '强调文字、选中态、底栏选中项与进度条；对比度不够时自动压暗 / 提亮。');

  const MeowColorKind(this._label, this._pickerTitle, this._caption);
  final String _label, _pickerTitle, _caption;

  /// [glass] = 液态玻璃主题
  String label(bool glass) => glass && this == card ? '底色' : _label;
  String pickerTitle(bool glass) => glass && this == card ? '自定义底色' : _pickerTitle;
  String caption(bool glass) => switch (this) {
    card when glass => '铺满整页的底色（取同色相的柔和渐层），内容卡片是半透明的玻璃；选「白」保持原来的底色。深色下取同色相的深底。',
    hero when glass => '电源键的液面颜色（液态玻璃下连接主卡和其它卡片一样是玻璃）；深色下取同色相的深色。',
    _ => _caption,
  };

  List<(String, int)> get presets => switch (this) {
    card => MeowCardColors.presets,
    hero => MeowHeroColors.presets,
    accent => MeowAccentColors.presets,
  };

  int of(MeowSettings s) => switch (this) {
    card => s.cardColor,
    hero => s.heroColor,
    accent => s.accentColor,
  };

  MeowSettings apply(MeowSettings s, int color) => switch (this) {
    card => s.copyWith(cardColor: color),
    hero => s.copyWith(heroColor: color),
    accent => s.copyWith(accentColor: color),
  };
}

/// 一种颜色的一行：6 个预设 + 自定义取色（两种主题都生效）。
class ColorChoiceRow extends ConsumerWidget {
  const ColorChoiceRow(this.kind, {super.key});

  final MeowColorKind kind;

  static const _swatch = 28.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = ref.watch(meowSettingProvider.select(kind.of));
    final glass = context.mm.glass;
    final name = kind.presets.where((p) => p.$2 == color).firstOrNull?.$1;
    return _StackedRow(
      label: kind.label(glass),
      value: name ?? '自定义 #${meowHexDigits(Color(color))}',
      caption: kind.caption(glass),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (label, c) in kind.presets)
            _Swatch(
              label: label,
              selected: c == color,
              size: _swatch,
              fill: BoxDecoration(color: Color(c), shape: BoxShape.circle),
              onTap: () => _update(ref, (s) => kind.apply(s, c)),
            ),
          _Swatch(
            label: '自定义',
            selected: name == null,
            size: _swatch,
            fill: const BoxDecoration(shape: BoxShape.circle, gradient: _rainbow),
            onTap: () => mePush(context, ColorPickerPage(kind: kind, initial: Color(color))),
          ),
        ],
      ),
    );
  }
}

/// 液态玻璃的「底色」：单色 / 渐变两种，上面一个分段切换，下面是对应的预设（单色同「卡片颜色」那一组，渐变是 [MeowBgGradients]）+ 自定义。
/// 存的仍是 cardColor（单色）与 bgStyle / bgGradientFrom / bgGradientTo（渐变），老配置没有后几项 = 单色。
class GlassBgRow extends ConsumerWidget {
  const GlassBgRow({super.key});

  static const _swatch = 28.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(meowSettingProvider.select((s) => s.bgStyle));
    final solid = ref.watch(meowSettingProvider.select((s) => s.cardColor));
    final from = ref.watch(meowSettingProvider.select((s) => s.bgGradientFrom));
    final to = ref.watch(meowSettingProvider.select((s) => s.bgGradientTo));
    final dense = MeDense.of(context);
    final gradient = style == MeowBgStyle.gradient;
    final String value;
    if (gradient) {
      value = MeowBgGradients.nameOf(from, to) ?? '自定义渐变';
    } else {
      value = MeowCardColors.nameOf(solid) ?? '自定义 #${meowHexDigits(Color(solid))}';
    }
    return _StackedRow(
      label: '底色',
      value: value,
      caption: gradient
          ? '两种颜色从左上到右下铺满整页，内容卡片是半透明的玻璃；深色下取同色相的深色渐变。'
          : MeowColorKind.card.caption(true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MeowSegment<MeowBgStyle>(
            items: [for (final v in MeowBgStyle.values) (v, v.label)],
            value: style,
            onCard: true,
            height: dense ? 32 : 38,
            fontSize: dense ? 12 : 13,
            onChanged: (v) => _update(ref, (s) => s.copyWith(bgStyle: v)),
          ),
          SizedBox(height: dense ? 8 : 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: gradient
                ? [
                    for (final (label, a, b) in MeowBgGradients.presets)
                      _Swatch(
                        label: label,
                        selected: a == from && b == to,
                        size: _swatch,
                        fill: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(a), Color(b)],
                          ),
                        ),
                        onTap: () => _update(ref, (s) => s.copyWith(bgGradientFrom: a, bgGradientTo: b)),
                      ),
                    _customSwatch(
                      selected: MeowBgGradients.nameOf(from, to) == null,
                      onTap: () => mePush(context, GradientPickerPage(from: Color(from), to: Color(to))),
                    ),
                  ]
                : [
                    for (final (label, c) in MeowCardColors.presets)
                      _Swatch(
                        label: label,
                        selected: c == solid,
                        size: _swatch,
                        fill: BoxDecoration(color: Color(c), shape: BoxShape.circle),
                        onTap: () => _update(ref, (s) => s.copyWith(cardColor: c)),
                      ),
                    _customSwatch(
                      selected: MeowCardColors.nameOf(solid) == null,
                      onTap: () => mePush(context, ColorPickerPage(kind: MeowColorKind.card, initial: Color(solid))),
                    ),
                  ],
          ),
        ],
      ),
    );
  }

  Widget _customSwatch({required bool selected, required VoidCallback onTap}) => _Swatch(
    label: '自定义',
    selected: selected,
    size: _swatch,
    fill: const BoxDecoration(shape: BoxShape.circle, gradient: _rainbow),
    onTap: onTap,
  );
}

/// 「自定义」色块的彩虹圈
const _rainbow = SweepGradient(
  colors: [
    Color(0xFFF3A6BF),
    Color(0xFFB3A2FF),
    Color(0xFF7CCFE0),
    Color(0xFF57D292),
    Color(0xFFF2B257),
    Color(0xFFF3A6BF),
  ],
);

class _Swatch extends StatelessWidget {
  const _Swatch({required this.label, required this.selected, required this.size, required this.fill, required this.onTap});

  final String label;
  final bool selected;
  final double size;
  final BoxDecoration fill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          // 选中 = 外面隔一圈玫红描边（不改色块本身的大小，换选中时整行不跳）
          child: Container(
            width: size + 8,
            height: size + 8,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? mm.accent : Colors.transparent, width: 2),
            ),
            child: Container(
              width: size,
              height: size,
              foregroundDecoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x1F000000))),
              decoration: fill,
            ),
          ),
        ),
      ),
    );
  }
}

/// 自定义颜色：浅 / 深两种外观下推出来的样子 + 取色器（移植自 FlClash 的 iOS 风格取色器）+ 十六进制输入，右上角确定。
/// 手机上在设置卡片里推入下一层，宽屏整页推入。
class ColorPickerPage extends ConsumerStatefulWidget {
  const ColorPickerPage({super.key, required this.kind, required this.initial});

  final MeowColorKind kind;
  final Color initial;

  @override
  ConsumerState<ColorPickerPage> createState() => _ColorPickerPageState();
}

class _ColorPickerPageState extends ConsumerState<ColorPickerPage> {
  late final _controller = ValueNotifier<Color>(widget.initial.withValues(alpha: 1));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final color = _controller.value.toARGB32() | 0xFF000000;
    _update(ref, (s) => widget.kind.apply(s, color));
    final sheet = MeSheetScope.maybeOf(context);
    if (sheet != null) {
      sheet.navigator.back();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeSubPage.list(
      title: widget.kind.pickerTitle(context.mm.glass),
      actions: [RoundGlassButton(icon: Icons.check_rounded, filled: true, tooltip: '确定', onTap: _confirm)],
      children: [
        ValueListenableBuilder(
          valueListenable: _controller,
          builder: (_, color, _) => ColorPreview(kind: widget.kind, color: color),
        ),
        MeSection(
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 12), child: MeowPalette(controller: _controller)),
          ],
        ),
        MeSection(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: ValueListenableBuilder(
                valueListenable: _controller,
                builder: (_, color, _) => MeowHexColorField(color: color, onChanged: (c) => _controller.value = c),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 自定义渐变底色：上面是浅 / 深两种外观下铺出来的样子，「起始色 / 结束色」切换正在调的那一端，取色器与十六进制输入同 [ColorPickerPage]。
/// 右上角确定后存两种颜色并切到「渐变」。
class GradientPickerPage extends ConsumerStatefulWidget {
  const GradientPickerPage({super.key, required this.from, required this.to});

  final Color from, to;

  @override
  ConsumerState<GradientPickerPage> createState() => _GradientPickerPageState();
}

class _GradientPickerPageState extends ConsumerState<GradientPickerPage> {
  late Color _from = widget.from.withValues(alpha: 1), _to = widget.to.withValues(alpha: 1);

  /// 0 = 起始色，1 = 结束色
  var _end = 0;
  late final _controller = ValueNotifier<Color>(_from)..addListener(_onPick);

  void _onPick() {
    final c = _controller.value;
    setState(() => _end == 0 ? _from = c : _to = c);
  }

  void _switch(int end) {
    setState(() => _end = end);
    _controller.value = end == 0 ? _from : _to;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    _update(
      ref,
      (s) => s.copyWith(
        bgStyle: MeowBgStyle.gradient,
        bgGradientFrom: _from.toARGB32() | 0xFF000000,
        bgGradientTo: _to.toARGB32() | 0xFF000000,
      ),
    );
    final sheet = MeSheetScope.maybeOf(context);
    if (sheet != null) {
      sheet.navigator.back();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dense = MeDense.of(context);
    return MeSubPage.list(
      title: '自定义渐变底色',
      actions: [RoundGlassButton(icon: Icons.check_rounded, filled: true, tooltip: '确定', onTap: _confirm)],
      children: [
        GradientPreview(from: _from, to: _to),
        MeSection(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MeowSegment<int>(
                    items: const [(0, '起始色（左上）'), (1, '结束色（右下）')],
                    value: _end,
                    onCard: true,
                    height: dense ? 32 : 38,
                    fontSize: dense ? 12 : 13,
                    onChanged: _switch,
                  ),
                  const SizedBox(height: 10),
                  MeowPalette(controller: _controller),
                ],
              ),
            ),
          ],
        ),
        MeSection(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: ValueListenableBuilder(
                valueListenable: _controller,
                builder: (_, color, _) => MeowHexColorField(color: color, onChanged: (c) => _controller.value = c),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 渐变底色在浅色 / 深色下铺出来的样子：斜向渐变的底上放一张玻璃卡片（跟着当前的玻璃样式）。
class GradientPreview extends StatelessWidget {
  const GradientPreview({super.key, required this.from, required this.to});

  final Color from, to;

  @override
  Widget build(BuildContext context) {
    final tinted = context.mm.glassTinted;
    Widget sample(String label, bool dark) {
      final base = dark ? MeowTokens.dark : MeowTokens.light;
      final g = MeowTokens.glassGradientShades(from, to, dark: dark, tinted: tinted);
      return Expanded(
        child: Container(
          height: 76,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: g.gradient!),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: MeowCardDecoration(
              color: g.card,
              borderRadius: BorderRadius.circular(12),
              rim: g.rim,
              sheen: g.sheen,
              shadow: g.shadow,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: base.t1),
                  ),
                ),
                Container(
                  width: 34,
                  height: 20,
                  decoration: BoxDecoration(color: g.card2, borderRadius: BorderRadius.circular(10)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(children: [sample('浅色', false), const SizedBox(width: 10), sample('深色', true)]);
  }
}

/// 选的颜色在浅色 / 深色下实际推出来的样子：卡片色 = 一张卡片配次级底（液态玻璃下是底色上放一张玻璃卡片）；
/// 启动卡片 = 主卡配电源键；强调色 = 强调字配淡底胶囊与进度条。
class ColorPreview extends StatelessWidget {
  const ColorPreview({super.key, required this.kind, required this.color});

  final MeowColorKind kind;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final glass = context.mm.glass;
    Widget sample(String label, bool dark) {
      final base = dark ? MeowTokens.dark : MeowTokens.light;
      final white = MeowTokens.glassShades(const Color(MeowCardColors.white), dark: dark);
      var bg = glass ? white.bg : base.bg;
      List<Color>? bgGradient;
      final card = glass ? Color.alphaBlend(white.card, white.bg) : base.elev;
      final text = TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: base.t1);
      final Widget inner;
      switch (kind) {
        case MeowColorKind.card when glass:
          final g = MeowTokens.glassShades(color, dark: dark, tinted: context.mm.glassTinted);
          bg = g.bg;
          bgGradient = g.gradient;
          inner = Container(
            padding: const EdgeInsets.all(10),
            decoration: MeowCardDecoration(
              color: g.card,
              borderRadius: BorderRadius.circular(12),
              rim: g.rim,
              sheen: g.sheen,
              shadow: g.shadow,
            ),
            child: Row(
              children: [
                Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text)),
                Container(
                  width: 34,
                  height: 20,
                  decoration: BoxDecoration(color: g.card2, borderRadius: BorderRadius.circular(10)),
                ),
              ],
            ),
          );
        case MeowColorKind.card:
          final shades = MeowTokens.cardShades(color, dark: dark);
          inner = Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: shades.card, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text)),
                Container(
                  width: 34,
                  height: 20,
                  decoration: BoxDecoration(color: shades.card2, borderRadius: BorderRadius.circular(10)),
                ),
              ],
            ),
          );
        case MeowColorKind.hero:
          // 液态玻璃下连接主卡和其它卡片一样是玻璃，启动卡片颜色只给电源键的液面
          final hero = MeowTokens.heroShades(color, dark: dark);
          inner = Container(
            padding: const EdgeInsets.all(10),
            decoration: glass
                ? MeowCardDecoration(
                    color: white.card,
                    borderRadius: BorderRadius.circular(12),
                    rim: white.rim,
                    sheen: white.sheen,
                    shadow: white.shadow,
                  )
                : BoxDecoration(color: hero.hero, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text)),
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: hero.btnOn, borderRadius: BorderRadius.circular(9)),
                  child: MeowIcon(MeowGlyph.power, size: 14, color: base.onBtn, stroke: 2.4),
                ),
              ],
            ),
          );
        case MeowColorKind.accent:
          final accent = MeowTokens.accentShades(color, dark: dark);
          inner = Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.copyWith(color: accent.accent)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: accent.soft,
                        border: Border.all(color: accent.accent, width: 1.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('选中', style: TextStyle(fontSize: MeowFont.caption2, color: accent.accent)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    height: 5,
                    child: Row(
                      children: [
                        Expanded(flex: 2, child: ColoredBox(color: accent.fill)),
                        Expanded(flex: 3, child: ColoredBox(color: base.card2)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
      }
      return Expanded(
        child: Container(
          height: 76,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: bgGradient == null ? bg : null,
            gradient: bgGradient == null
                ? null
                : LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: bgGradient),
            borderRadius: BorderRadius.circular(18),
          ),
          child: inner,
        ),
      );
    }

    return Row(children: [sample('浅色', false), const SizedBox(width: 10), sample('深色', true)]);
  }
}
