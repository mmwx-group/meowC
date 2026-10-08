import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../state/format.dart';
import '../../state/status.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';

/// 网速卡：上传 / 下载两列（速率大字 + 会话累计）+ 近 60 秒折线，折线贴着卡片左右和底边。
/// [up] / [down] / [chart] 对应「首页卡片」里的三个开关，调用方保证至少开着一个。
/// [expand]：外层给了定高（宽屏左列撑满），折线吃掉剩余高度；否则折线定高。
class HomeSpeedCard extends ConsumerWidget {
  const HomeSpeedCard({
    super.key,
    this.up = true,
    this.down = true,
    this.chart = true,
    this.dense = false,
    this.expand = false,
  });

  final bool up, down, chart, dense, expand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final running = ref.watch(isRunningProvider);
    // 两份数据每秒各变一次：不在首页时不跟（数据照常在 provider 里攒着，切回来那一帧折线直接画到最新）
    final traffics = ref.watchOnTab(MeowTab.home, trafficsProvider).list;
    final total = ref.watchOnTab(MeowTab.home, totalTrafficProvider);
    final last = traffics.isEmpty ? null : traffics.last;
    final recent = traffics.length > 60 ? traffics.sublist(traffics.length - 60) : traffics;
    final ups = [for (final t in recent) t.up.value.toDouble()];
    final downs = [for (final t in recent) t.down.value.toDouble()];
    final peak = [...ups, ...downs].fold<double>(0, (m, v) => v > m ? v : m);
    final hasRates = up || down;
    final caption = TextStyle(fontSize: 11, color: mm.t2);

    Widget rate(MeowGlyph glyph, Color color, String label, int value, int session) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            MeowIcon(glyph, size: dense ? 12 : 13, color: color),
            const SizedBox(width: 4),
            // 会话累计是这行的重点，窄屏 + 大字号放不下时整体缩小，不截掉数字
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '$label · ${S.session} ${fmtSize(session)}',
                  maxLines: 1,
                  style: TextStyle(fontSize: dense ? 11 : 12, color: mm.t2),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: dense ? 1 : 2),
        // 放不下时整体缩小，不截成「12.3 M…」
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            fmtRate(value),
            maxLines: 1,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: mm.t1,
              fontFamilyFallback: meowRounded,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );

    final painter = CustomPaint(
      size: Size.infinite,
      painter: _SpeedPainter(
        up: ups,
        down: downs,
        upColor: mm.accent,
        downColor: mm.down,
        idleColor: mm.line,
        running: running,
        fill: dense,
      ),
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(dense ? 22 : 24)),
      padding: EdgeInsets.only(top: dense ? 12 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expand && chart ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (hasRates)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (up) Expanded(child: rate(MeowGlyph.up, mm.accent, S.upload, last?.up.value ?? 0, total.up.value)),
                  if (up && down) const SizedBox(width: 12),
                  if (down) Expanded(child: rate(MeowGlyph.down, mm.down, S.download, last?.down.value ?? 0, total.down.value)),
                ],
              ),
            ),
          if (chart) ...[
            // 手机端有两列速率时不要这行说明（设计稿只有折线）；速率都关掉、只剩折线时补上，否则看不出画的是什么
            if (dense || !hasRates)
              Padding(
                padding: EdgeInsets.fromLTRB(16, hasRates ? 6 : 0, 16, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(child: Text('近 60 秒', maxLines: 1, overflow: TextOverflow.ellipsis, style: caption)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text('${S.peak} ${fmtRate(peak)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            if (expand)
              Expanded(child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 24), child: painter))
            else
              SizedBox(height: dense ? 84 : 34, child: painter),
          ] else
            SizedBox(height: dense ? 12 : 14),
        ],
      ),
    );
  }
}

/// 近 60 秒双线：下载紫在下层、上传玫红在上层，线宽 2；不到 60 个点时靠右。未连接画一条虚线。
class _SpeedPainter extends CustomPainter {
  _SpeedPainter({
    required this.up,
    required this.down,
    required this.upColor,
    required this.downColor,
    required this.idleColor,
    required this.running,
    required this.fill,
  });

  final List<double> up, down;
  final Color upColor, downColor, idleColor;
  final bool running;

  /// 下载线下方铺 10% 的底色（宽屏那张大图用）
  final bool fill;

  static const _points = 60;

  @override
  void paint(Canvas canvas, Size size) {
    if (!running) {
      final paint = Paint()
        ..color = idleColor
        ..strokeWidth = 1;
      final y = size.height / 2;
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(x + 4, y), paint);
      }
      return;
    }
    final maxV = [...up, ...down].fold<double>(0, (m, v) => v > m ? v : m);
    // 上下各留 2：线宽 2，贴着顶 / 底会被裁掉一半
    final scale = maxV <= 0 ? 0.0 : (size.height - 4) * 0.9 / maxV;
    final dx = size.width / (_points - 1);
    void line(List<double> data, Color color, {required bool fill}) {
      if (data.length < 2) return;
      final start = _points - data.length;
      final path = Path();
      for (var i = 0; i < data.length; i++) {
        final x = (start + i) * dx;
        final y = size.height - 2 - data[i] * scale;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      if (fill) {
        final area = Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(start * dx, size.height)
          ..close();
        canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.10));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
    }

    line(down, downColor, fill: fill);
    line(up, upColor, fill: false);
  }

  @override
  bool shouldRepaint(covariant _SpeedPainter old) =>
      old.up != up ||
      old.down != down ||
      old.running != running ||
      old.fill != fill ||
      old.upColor != upColor ||
      old.downColor != downColor ||
      old.idleColor != idleColor;
}
