import 'package:flutter/material.dart';

import 'svg_path.dart';
import 'tokens.dart';

/// 设计稿里的线性图标（24 网格、1.9 描边、圆头圆角）。Material 图标集里没有同形的，按稿子的路径画。
enum MeowGlyph {
  home('M4 11l8-7 8 7v8a1 1 0 0 1-1 1h-4v-6h-6v6H5a1 1 0 0 1-1-1z'),
  nodes(
    'M6 9.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5M18 3.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5'
    'M18 15.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5M8.2 10.8l7.6-3.6M8.2 13.2l7.6 3.6',
  ),
  activity('M3 12h4l3-8 4 16 3-8h4'),
  me('M12 4a4 4 0 1 0 0 8 4 4 0 0 0 0-8M4 21a8 8 0 0 1 16 0'),
  power('M12 3v9M6.3 6.3a8 8 0 1 0 11.4 0'),
  chevron('M9 6l6 6-6 6'),
  updown('M8 9l4-4 4 4M8 15l4 4 4-4'),
  refresh('M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5'),
  sliders('M4 7h10M18 7h2M4 17h2M10 17h10M16 5a2 2 0 1 0 0 4 2 2 0 0 0 0-4M8 15a2 2 0 1 0 0 4 2 2 0 0 0 0-4'),
  apps('M6 4h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2M15 4h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2h-3a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2'
      'M6 13h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2M14 17l2 2 4-4'),
  search('M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14M20 20l-3.5-3.5'),
  close('M6 6l12 12M18 6L6 18'),
  back('M15 6l-6 6 6 6'),
  up('M12 19V5M6 11l6-6 6 6'),
  down('M12 5v14M6 13l6 6 6-6');

  const MeowGlyph(this.d);
  final String d;
}

class MeowIcon extends StatelessWidget {
  const MeowIcon(MeowGlyph this.glyph, {super.key, double this.size = 22, this.color, this.stroke = 1.9}) : _d = null;

  /// 尺寸和颜色都跟外层 [IconTheme] 走（放进液态玻璃底栏这类由容器给图标定色定大小的地方）。
  const MeowIcon.themed(MeowGlyph this.glyph, {super.key, this.stroke = 1.9}) : size = null, color = null, _d = null;

  /// 直接给路径（24 网格的 SVG path `d`）：个别页面自己的图标，不进 [MeowGlyph]。
  const MeowIcon.path(String d, {super.key, double this.size = 22, this.color, this.stroke = 1.9}) : glyph = null, _d = d;

  final MeowGlyph? glyph;
  final String? _d;
  final double? size;
  final Color? color;
  final double stroke;

  /// 路径只解析一次（按 `d` 字符串）；描边粗细和颜色是画的时候才给的，不进这张表。
  static final _paths = <String, Path>{};

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final c = color ?? theme.color ?? context.mm.t1;
    final size = this.size ?? theme.size ?? 22;
    final d = glyph?.d ?? _d!;
    // 直接把路径画到画布上、颜色进画笔。以前是 SvgPicture.string + colorFilter：每个图标每次光栅化都要开一个离屏层，
    // 每种图标第一次出现还要起一个 isolate 解析 SVG、晚一两帧才出图。
    // 外面这层语义是 flutter_svg 原来就带的（标成图片、没有文字），留着，读屏听到的不变。
    return Semantics(
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(_paths[d] ??= parseSvgPath(d), c, stroke),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.path, this.color, this.stroke);

  final Path path;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    // 和 SVG 的摆法一样：24 网格等比缩进盒子、居中；描边粗细是网格里的数，跟着图标一起缩放。
    // 路径连描边都在 24 网格以内，不再另外裁一刀
    final scale = size.shortestSide / 24;
    canvas
      ..save()
      ..translate((size.width - 24 * scale) / 2, (size.height - 24 * scale) / 2)
      ..scale(scale)
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.path != path || old.color != color || old.stroke != stroke;
}

/// 分段选择：卡片底胶囊里放等宽分段，选中 = 墨色底配页面底色的字。
/// [onCard] = 放在白卡片上时槽用次级底（放在主卡 / 页面底上时槽用卡片底）。
class MeowSegment<T> extends StatelessWidget {
  const MeowSegment({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.height = 44,
    this.onCard = false,
    this.fontSize = 14,
  });

  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;
  final bool onCard;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final outer = height >= 40 ? 14.0 : 11.0;
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: onCard ? mm.card2 : mm.elev, borderRadius: BorderRadius.circular(outer)),
      child: Row(
        children: [
          for (final (i, it) in items.indexed) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Semantics(
                button: true,
                selected: it.$1 == value,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(it.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    constraints: BoxConstraints(minHeight: height - 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: it.$1 == value ? mm.t1 : Colors.transparent,
                      borderRadius: BorderRadius.circular(outer - 3),
                    ),
                    child: Text(
                      it.$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: it.$1 == value ? FontWeight.w600 : FontWeight.w500,
                        color: it.$1 == value ? mm.bg : mm.t2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 电源键：已连接 = 樱粉底 + 粉色光晕；未连接 = 墨色底；不可用 = 半透明。
class MeowPowerButton extends StatelessWidget {
  const MeowPowerButton({
    super.key,
    required this.on,
    required this.onTap,
    this.enabled = true,
    this.busy = false,
    this.size = 80,
  });

  final bool on, enabled, busy;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final bg = on ? mm.btnOn : mm.t1;
    final fg = on ? mm.onBtn : mm.bg;
    final glyph = size * 0.43;
    return Semantics(
      button: true,
      enabled: enabled,
      label: on ? '断开连接' : '连接',
      child: Opacity(
        opacity: enabled || busy ? 1 : 0.4,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(size * 0.325),
              boxShadow: [
                BoxShadow(
                  color: on ? mm.pink.withValues(alpha: 0.5) : const Color(0x382A2130),
                  blurRadius: size * 0.25,
                  offset: Offset(0, size * 0.1),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: busy
                ? SizedBox(
                    width: glyph * 0.7,
                    height: glyph * 0.7,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
                  )
                : MeowIcon(MeowGlyph.power, size: glyph, color: fg, stroke: 2.2),
          ),
        ),
      ),
    );
  }
}

/// 地区码小标签（HK / JP …）：只用于出口 IP 查到的归属地代码。节点名里的国旗原样显示（和代理组名一个画法），不再换成这个标签。
/// [large] = 34×24 的大号。
class RegionTag extends StatelessWidget {
  const RegionTag(this.code, {super.key, this.large = false});
  final String code;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final text = Text(
      code,
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
      style: TextStyle(fontSize: large ? 11 : 10, fontWeight: FontWeight.w700, color: mm.t2, height: 1.2),
    );
    if (large) {
      return Container(
        constraints: const BoxConstraints(minWidth: 34, minHeight: 24),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(7)),
        child: text,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(5)),
      child: text,
    );
  }
}

/// 行首的图标方块：柔粉底 + 玫红图标（[tint] 可换色，底取它的 14%）。
class IconTile extends StatelessWidget {
  const IconTile({super.key, this.icon, this.glyph, this.size = 32, this.tint});
  final IconData? icon;
  final MeowGlyph? glyph;
  final double size;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final fg = tint ?? mm.accent;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint == null ? mm.soft : fg.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.31),
      ),
      child: glyph != null ? MeowIcon(glyph!, size: size * 0.53, color: fg) : Icon(icon, size: size * 0.56, color: fg),
    );
  }
}

/// 状态小圆点 + 文案。
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// 品牌头像（浅 / 深两张，随主题切）。
class BrandHead extends StatelessWidget {
  const BrandHead({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.31),
      // 256 的小图（scripts/make-brand-assets.py 从 1024 的那张缩好的）：整张 1024 解码后 4MB 多，这里最大只画 60dp。
      // 不用 cacheWidth 让引擎现缩——那是不带 mipmap 的双线性，缩这么多倍会出锯齿。
      child: Image.asset(
        dark ? 'assets/images/icon_256.png' : 'assets/images/icon_light_256.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}

/// 圆角字体族：标题 / 大数字用（系统没有圆体时回落到默认字体）。
const meowRounded = <String>['Google Sans', 'Segoe UI Variable Display', 'Segoe UI', 'Microsoft YaHei UI', 'Noto Sans SC'];
