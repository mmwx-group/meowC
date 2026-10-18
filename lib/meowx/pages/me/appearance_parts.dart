import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/meow_settings.dart';
import '../../theme/color_picker.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import 'me_kit.dart';

/// 「我的 › 外观」里主题风格 / 玻璃样式 / 卡片颜色 / 启动卡片颜色 / 强调色几行（[AppearanceRows] 用；手机在底部卡片里，宽屏铺在「外观 · 关于」分组里）。

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
        color: selected ? mm.soft : mm.card2,
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

/// 缩略图（设计稿同款）：页面底 + 樱粉主卡 + 一张卡片 + 底栏胶囊；液态玻璃那张的底栏是带高光的半透明玻璃。
/// 只是示意图：用普通的半透明与描边画，不放真玻璃（设置页不多出玻璃层）。
class _StyleThumb extends StatelessWidget {
  const _StyleThumb({required this.glass});

  final bool glass;

  @override
  Widget build(BuildContext context) {
    final dark = context.isDarkMode;
    final base = dark ? MeowTokens.dark : MeowTokens.light;
    final spec = MeowGlassSpec.of(dark);
    final bg = glass ? spec.bg : base.bg;
    final card = glass && dark ? const Color(0xFF1C1A20) : base.elev;
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
                  color: glass ? null : base.hero,
                  gradient: glass ? LinearGradient(colors: spec.hero) : null,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              top: 28,
              height: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(5)),
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
enum MeowColorKind {
  card('卡片颜色', '自定义卡片颜色', '只改内容卡片，玻璃控件不变；深色下取同色相的深色卡片。'),
  hero('启动卡片颜色', '自定义启动卡片颜色', '首页连接主卡与电源键；深色下取同色相的深色。'),
  accent('强调色', '自定义强调色', '强调文字、选中态、底栏选中项与进度条；对比度不够时自动压暗 / 提亮。');

  const MeowColorKind(this.label, this.pickerTitle, this.caption);
  final String label, pickerTitle, caption;

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
    final name = kind.presets.where((p) => p.$2 == color).firstOrNull?.$1;
    return _StackedRow(
      label: kind.label,
      value: name ?? '自定义 #${meowHexDigits(Color(color))}',
      caption: kind.caption,
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
            fill: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  Color(0xFFF3A6BF),
                  Color(0xFFB3A2FF),
                  Color(0xFF7CCFE0),
                  Color(0xFF57D292),
                  Color(0xFFF2B257),
                  Color(0xFFF3A6BF),
                ],
              ),
            ),
            onTap: () => mePush(context, ColorPickerPage(kind: kind, initial: Color(color))),
          ),
        ],
      ),
    );
  }
}

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
      title: widget.kind.pickerTitle,
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

/// 选的颜色在浅色 / 深色下实际推出来的样子：卡片色 = 一张卡片配次级底；启动卡片 = 主卡配电源键；强调色 = 强调字配淡底胶囊与进度条。
class ColorPreview extends StatelessWidget {
  const ColorPreview({super.key, required this.kind, required this.color});

  final MeowColorKind kind;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final glass = context.mm.glass;
    Widget sample(String label, bool dark) {
      final base = dark ? MeowTokens.dark : MeowTokens.light;
      final bg = glass ? MeowGlassSpec.of(dark).bg : base.bg;
      final card = MeowTokens.cardShades(const Color(MeowCardColors.white), dark: dark, glass: glass).card;
      final text = TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: base.t1);
      final Widget inner;
      switch (kind) {
        case MeowColorKind.card:
          final shades = MeowTokens.cardShades(color, dark: dark, glass: glass);
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
          final hero = MeowTokens.heroShades(color, dark: dark);
          inner = Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: glass ? null : hero.hero,
              gradient: glass ? LinearGradient(colors: hero.gradient) : null,
              borderRadius: BorderRadius.circular(12),
            ),
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
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
          child: inner,
        ),
      );
    }

    return Row(children: [sample('浅色', false), const SizedBox(width: 10), sample('深色', true)]);
  }
}
