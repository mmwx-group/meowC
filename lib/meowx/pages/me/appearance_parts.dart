import 'dart:io';

import 'package:bett_box/common/constant.dart' show minTextScale, maxTextScale;
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart' show themeSettingProvider;
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_icon.dart';
import '../../state/meow_settings.dart';
import '../../state/ui_prefs.dart';
import '../../theme/color_picker.dart';
import '../../theme/haptics.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import 'me_kit.dart';

/// 「我的 › 外观」里主题色 / 跟随系统取色 / App 图标几行（[AppearanceRows] 用）。M3 改版（2026-11）后外观只剩这几项：
/// 整套配色由一个种子色生成（[MeowColors.scheme]），深浅色沿用 Bettbox 的 themeMode。

void _update(WidgetRef ref, MeowSettings Function(MeowSettings s) f) =>
    ref.read(meowSettingProvider.notifier).updateState(f);

/// 这台设备能不能跟随系统取色：安卓 12+ 有桌布色板，Windows 有系统强调色
bool get meowSystemColorAvailable => globalState.corePalette != null || Platform.isWindows;

/// 一行的骨架：标题（+ 右侧小字）在上，控件在下（这几项的控件都比一行宽，不放行尾）。
class _StackedRow extends StatelessWidget {
  const _StackedRow({required this.label, this.value, required this.child, this.caption});

  final String label;
  final String? value;
  final Widget child;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final dense = MeDense.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, dense ? 10 : 14, 16, dense ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: dense ? MeowFont.callout : MeowFont.body,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value ?? '',
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: MeowFont.footnote, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
          SizedBox(height: dense ? 10 : 12),
          child,
          if (caption != null) ...[
            const SizedBox(height: 10),
            Text(caption!, style: TextStyle(fontSize: MeowFont.caption, color: cs.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

/// 跟随系统取色（只在设备支持时出现）：打开后主题色那一行变灰。
class FollowSystemColorRow extends ConsumerWidget {
  const FollowSystemColorRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(meowSettingProvider.select((s) => s.followSystemColor));
    return MeSwitchRow(
      label: '跟随系统取色',
      subtitle: Platform.isWindows ? '用 Windows 的强调色生成配色' : '用桌布的颜色生成配色',
      value: on,
      onChanged: (v) => _update(ref, (s) => s.copyWith(followSystemColor: v)),
    );
  }
}

/// 主题色：八个预设（每个画成「主色 / 次色容器 / 第三色容器」三分圆，同安卓「壁纸与风格」的取色块）+ 自定义。
class ThemeColorRow extends ConsumerWidget {
  const ThemeColorRow({super.key});

  static const _swatch = 44.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(meowSettingProvider.select((s) => s.accentColor));
    final follow = meowSystemColorAvailable && ref.watch(meowSettingProvider.select((s) => s.followSystemColor));
    final name = MeowColors.nameOf(seed);
    final brightness = Theme.of(context).brightness;
    return _StackedRow(
      label: '主题色',
      value: follow ? '跟随系统' : (name ?? '自定义 #${meowHexDigits(Color(seed))}'),
      caption: follow ? '正在跟随系统取色，关掉上面的开关后才用这里选的颜色。' : '整套界面的配色都由它生成，深色下自动换成同色相的深色调。',
      child: IgnorePointer(
        ignoring: follow,
        child: AnimatedOpacity(
          opacity: follow ? 0.38 : 1,
          duration: MeowSprings.effectsDuration,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (label, c) in MeowColors.presets)
                SeedSwatch(
                  label: label,
                  seed: Color(c),
                  brightness: brightness,
                  selected: !follow && c == seed,
                  size: _swatch,
                  onTap: () => _update(ref, (s) => s.copyWith(accentColor: c)),
                ),
              _CustomSwatch(
                selected: !follow && name == null,
                size: _swatch,
                onTap: () => mePush(context, ColorPickerPage(initial: Color(seed))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一个种子色的取色块：上半是主色、左下次色容器、右下第三色容器；选中 = 由圆变成圆角方块 + 中间一个勾（弹簧插值）。
class SeedSwatch extends StatelessWidget {
  const SeedSwatch({
    super.key,
    required this.label,
    required this.seed,
    required this.brightness,
    required this.selected,
    required this.size,
    required this.onTap,
  });

  final String label;
  final Color seed;
  final Brightness brightness;
  final bool selected;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = MeowColors.scheme(seed, brightness);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: selected ? 1 : 0),
            duration: MeowSprings.shapeDuration,
            curve: MeowSprings.shapeCurve,
            builder: (_, t, _) {
              final k = t.clamp(0.0, 1.0);
              return SizedBox.square(
                dimension: size,
                child: CustomPaint(
                  painter: _SeedPainter(
                    top: cs.primary,
                    left: cs.secondaryContainer,
                    right: cs.tertiaryContainer,
                    // 圆角：半径（圆）→ 30% 边长（圆角方块）；回弹越过 1 时不让它比方块更方
                    radius: size / 2 - (size / 2 - size * 0.3) * k,
                  ),
                  child: Center(
                    child: Opacity(
                      opacity: k,
                      child: Container(
                        width: size * 0.46,
                        height: size * 0.46,
                        decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
                        child: Icon(Icons.check_rounded, size: size * 0.3, color: cs.onPrimaryContainer),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SeedPainter extends CustomPainter {
  const _SeedPainter({required this.top, required this.left, required this.right, required this.radius});

  final Color top, left, right;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    final half = size.height / 2;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, half), Paint()..color = top);
    canvas.drawRect(Rect.fromLTWH(0, half, size.width / 2, half), Paint()..color = left);
    canvas.drawRect(Rect.fromLTWH(size.width / 2, half, size.width / 2, half), Paint()..color = right);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SeedPainter old) =>
      old.top != top || old.left != left || old.right != right || old.radius != radius;
}

/// 「自定义」取色块：彩虹圈 + 中间一支笔；选中同 [SeedSwatch]。
class _CustomSwatch extends StatelessWidget {
  const _CustomSwatch({required this.selected, required this.size, required this.onTap});

  final bool selected;
  final double size;
  final VoidCallback onTap;

  static const _rainbow = SweepGradient(
    colors: [
      Color(0xFFF3A6BF),
      Color(0xFFB3A2FF),
      Color(0xFF7CCFE0),
      Color(0xFF57D292),
      Color(0xFFF2B257),
      Color(0xFFF3A6BF),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Tooltip(
      message: '自定义',
      child: Semantics(
        button: true,
        selected: selected,
        label: '自定义',
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: MeowSprings.shapeDuration,
            curve: MeowSprings.shapeCurve,
            width: size,
            height: size,
            decoration: BoxDecoration(
              gradient: _rainbow,
              borderRadius: BorderRadius.circular(selected ? size * 0.3 : size / 2),
            ),
            child: Center(
              child: Container(
                width: size * 0.46,
                height: size * 0.46,
                decoration: BoxDecoration(color: cs.surfaceContainerLowest, shape: BoxShape.circle),
                child: Icon(selected ? Icons.check_rounded : Icons.edit_rounded, size: size * 0.26, color: cs.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// App 图标（只 Android）：几种图标并排，选中 = 主色描边 + 次色容器底。
class AppIconRow extends ConsumerWidget {
  const AppIconRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appIconProvider).valueOrNull;
    return _StackedRow(
      label: 'App 图标',
      caption: _appIconCaption,
      // 六款排两行、每行三个（2026-11-17 加了「X」三款）
      child: Column(
        children: [
          for (var row = 0; row * 3 < MeowAppIcon.values.length; row++) ...[
            if (row > 0) const SizedBox(height: 8),
            Row(
              children: [
                for (var col = 0; col < 3; col++) ...[
                  if (col > 0) const SizedBox(width: 8),
                  Expanded(
                    child: row * 3 + col < MeowAppIcon.values.length
                        ? _AppIconChoice(
                            icon: MeowAppIcon.values[row * 3 + col],
                            selected: MeowAppIcon.values[row * 3 + col] == current,
                            onTap: () => ref.read(appIconProvider.notifier).select(MeowAppIcon.values[row * 3 + col]),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
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
    final cs = context.cs;
    final dense = MeDense.of(context);
    final side = dense ? 44.0 : 56.0;
    return Semantics(
      button: true,
      selected: selected,
      label: icon.label,
      excludeSemantics: true,
      child: Material(
        color: selected ? cs.secondaryContainer : cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MeowShape.l),
          side: BorderSide(color: selected ? cs.primary : Colors.transparent, width: 2),
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
                    color: selected ? cs.onSecondaryContainer : cs.onSurface,
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

/// 自定义主题色：上面是浅 / 深两种外观下生成的配色样子 + 取色器 + 十六进制输入，右上角确定。
class ColorPickerPage extends ConsumerStatefulWidget {
  const ColorPickerPage({super.key, required this.initial});

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
    _update(ref, (s) => s.copyWith(accentColor: color));
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return MeSubPage.list(
      title: '自定义主题色',
      actions: [RoundGlassButton(icon: Icons.check_rounded, filled: true, tooltip: '确定', onTap: _confirm)],
      children: [
        ValueListenableBuilder(
          valueListenable: _controller,
          builder: (_, color, _) => SchemePreview(seed: color),
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

/// 一个种子色在浅色 / 深色下生成的配色：一张卡片上放主按钮、色调胶囊、第三色圆点与一段进度条。
class SchemePreview extends StatelessWidget {
  const SchemePreview({super.key, required this.seed});

  final Color seed;

  @override
  Widget build(BuildContext context) {
    Widget pill(String text, Color bg, Color fg) => Flexible(
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(MeowShape.full)),
        child: Text(
          text,
          maxLines: 1,
          style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w700, color: fg),
        ),
      ),
    );

    Widget sample(String label, Brightness brightness) {
      final cs = MeowColors.scheme(seed, brightness);
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(MeowShape.lInc)),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.card, borderRadius: BorderRadius.circular(MeowShape.l)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w800, color: cs.onSurface),
                      ),
                    ),
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(color: cs.tertiary, shape: BoxShape.circle),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    pill('连接', cs.primary, cs.onPrimary),
                    const SizedBox(width: 6),
                    pill('规则', cs.secondaryContainer, cs.onSecondaryContainer),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 4,
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        flex: 2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [sample('浅色', Brightness.light), const SizedBox(width: 10), sample('深色', Brightness.dark)]),
    );
  }
}

/// 文字缩放（原 Bettbox「主题」页）：开关 + 打开后下面一条滑杆（80%–140%）。
class TextScaleRow extends ConsumerWidget {
  const TextScaleRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(themeSettingProvider.select((s) => s.textScale));
    void update(TextScale Function(TextScale) f) =>
        ref.read(themeSettingProvider.notifier).updateState((s) => s.copyWith(textScale: f(s.textScale)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeSwitchRow(
          label: '文字缩放',
          subtitle: scale.enable ? '${(scale.scale * 100).round()}%' : '跟随系统字号',
          value: scale.enable,
          onChanged: (v) => update((t) => t.copyWith(enable: v)),
        ),
        if (scale.enable)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Slider(
              min: minTextScale,
              max: maxTextScale,
              divisions: ((maxTextScale - minTextScale) / 0.05).round(),
              label: '${(scale.scale * 100).round()}%',
              value: scale.scale.clamp(minTextScale, maxTextScale),
              onChanged: (v) => update((t) => t.copyWith(scale: v)),
            ),
          ),
      ],
    );
  }
}

/// 视觉主题预设：5 套内置风格（静谧雾白 / iOS 27 液态玻璃 / 暗夜极客 / 樱雾琉璃 / 莫兰迪柔雾）。
/// 底层卡片一律保持清透实底 + 极细描边；切到「iOS 27 液态玻璃」时，Dock 与弹出层启用更明显的光学边缘折射与高光。
class ThemePresetRow extends ConsumerWidget {
  const ThemePresetRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(meowUiPrefsProvider.select((s) => s.preset));
    final dark = context.isDarkMode;
    return _StackedRow(
      label: '视觉主题',
      value: preset.label,
      caption: preset.subtitle,
      child: SizedBox(
        height: 92,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: MeowVisualPreset.values.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (ctx, i) {
            final p = MeowVisualPreset.values[i];
            final selected = p == preset;
            final cs = ctx.cs;
            final bg = dark ? p.previewBgDark : p.previewBgLight;
            final cardColor = dark ? Color.lerp(bg, Colors.white, 0.08)! : Colors.white;
            return GestureDetector(
              onTap: () {
                MeowHaptics.select();
                ref.read(meowUiPrefsProvider.notifier).update((s) => s.copyWith(preset: p));
              },
              child: AnimatedContainer(
                duration: MeowSprings.effectsDuration,
                width: 108,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(MeowShape.l),
                  border: Border.all(
                    color: selected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.6),
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35), width: 0.6),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(color: p.previewAccent, shape: BoxShape.circle),
                                ),
                                const Spacer(),
                                if (p == MeowVisualPreset.ios27Glass)
                                  Icon(Icons.auto_awesome_rounded, size: 12, color: p.previewAccent),
                              ],
                            ),
                            Container(
                              height: 5,
                              width: 44,
                              decoration: BoxDecoration(
                                color: p.previewAccent.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      p.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                        color: selected ? cs.primary : (dark ? Colors.white : const Color(0xFF14161B)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Dock 与弹出层（气泡 / 菜单 / 对话框）的液态玻璃调节：不影响底层实色卡片。
class GlassOverlayRow extends ConsumerWidget {
  const GlassOverlayRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frost = ref.watch(meowUiPrefsProvider.select((s) => s.glassFrost));
    final tinted = ref.watch(meowUiPrefsProvider.select((s) => s.glassTinted));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeSwitchRow(
          label: 'Dock 与弹出层高对比玻璃',
          subtitle: '开启后底栏与弹窗使用更厚实的着色玻璃，底层卡片始终保持清晰实底',
          value: tinted,
          onChanged: (v) => ref.read(meowUiPrefsProvider.notifier).update((s) => s.copyWith(glassTinted: v)),
        ),
        _StackedRow(
          label: '玻璃模糊与折射强度',
          value: '${(frost * 100).round()}%',
          child: Slider(
            min: 0.0,
            max: 1.0,
            divisions: 10,
            value: frost,
            onChanged: (v) => ref.read(meowUiPrefsProvider.notifier).update((s) => s.copyWith(glassFrost: v)),
          ),
        ),
      ],
    );
  }
}

/// 灵动动效强度：柔和 / 标准 / 灵动，统一调节弹簧回弹与切换速度。
class MotionLevelRow extends ConsumerWidget {
  const MotionLevelRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = ref.watch(meowUiPrefsProvider.select((s) => s.motionLevel));
    return _StackedRow(
      label: '灵动动效',
      value: level.label,
      caption: '调节电源流体光环、分段滑块、弹出层与卡片自适应重排的弹簧回弹强度。',
      child: MeowSlideSegment<MeowMotionLevel>(
        items: const [
          (MeowMotionLevel.soft, '柔和'),
          (MeowMotionLevel.standard, '标准'),
          (MeowMotionLevel.lively, '灵动'),
        ],
        selected: level,
        height: 40,
        onChanged: (v) => ref.read(meowUiPrefsProvider.notifier).update((s) => s.copyWith(motionLevel: v)),
      ),
    );
  }
}
