import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../state/format.dart';
import '../../state/speed_history.dart';
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
    // 折线用自己攒的 60 秒（Bettbox 只留 30 个点，见 speed_history.dart）：每次推送都喂进缓冲。
    // 不在首页时只有这个监听回调在跑（不重建、不要帧）；在首页时每秒重建，下面再补喂一次。
    final buffer = ref.read(speedHistoryBufferProvider);
    ref.listen(trafficsProvider, (_, next) => buffer.feed(next.list));
    final traffics = ref.watchOnTab(MeowTab.home, trafficsProvider).list;
    final total = ref.watchOnTab(MeowTab.home, totalTrafficProvider);
    final last = traffics.isEmpty ? null : traffics.last;
    buffer.feed(traffics);
    final history = buffer.state;
    final peak = [...history.up, ...history.down].fold<double>(0, (m, v) => v > m ? v : m);
    final hasRates = up || down;
    final caption = TextStyle(fontSize: 11, color: mm.t2);

    // 两列各自居中（与 iOS / iPad 首页一致；之前照画板靠左）
    Widget rate(MeowGlyph glyph, Color color, String label, int value, int session) => Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MeowIcon(glyph, size: dense ? 12 : 13, color: color),
            const SizedBox(width: 4),
            // 会话累计是这行的重点，窄屏 + 大字号放不下时整体缩小，不截掉数字
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
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

    final painter = _SpeedChart(
      history: history,
      // 只在首页是当前页时动：隐藏页外层虽有 TickerMode，这里自己也管住，不在首页就不要帧
      active: ref.watch(meowTabProvider.select((t) => t == MeowTab.home)),
      upColor: mm.accent,
      downColor: mm.down,
      idleColor: mm.line,
      running: running,
      fill: dense,
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

/// 近 60 秒双线：下载紫在下层、上传玫红在上层，线宽 2。未连接画一条虚线。
///
/// 连续绘制（与 iOS / macOS 的 `SpeedSparkline` 同一套画法）：样本每秒来一个，以前每来一个就整体重画、所有点一下子
/// 左移一格（一顿一顿的）。现在按帧重画：线头是「倒数第二个点 → 最新点」之间按时间插值的位置，一直平滑地往前画；
/// 开头从左边起点往右画，画到右边缘之后整条线才开始匀速左移、线头停在右边缘继续画；纵轴最大值约 0.25 秒渐变过去。
/// 每秒只移几个像素，约 24 帧足够顺；首页不在前台时外层的 TickerMode 会停掉它，系统关了动画就按静态画（线头直接是最新点）。
class _SpeedChart extends StatefulWidget {
  const _SpeedChart({
    required this.history,
    required this.active,
    required this.upColor,
    required this.downColor,
    required this.idleColor,
    required this.running,
    required this.fill,
  });

  final SpeedHistoryState history;

  /// 首页是不是当前页：不是就停掉逐帧重画
  final bool active;
  final Color upColor, downColor, idleColor;
  final bool running;

  /// 下载线下方铺 10% 的底色（宽屏那张大图用）
  final bool fill;

  @override
  State<_SpeedChart> createState() => _SpeedChartState();
}

class _SpeedChartState extends State<_SpeedChart> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final _repaint = _Repaint();
  final _motion = _ChartMotion();
  Duration _lastFrame = Duration.zero;

  /// 约 24 帧：折线每秒只移几个像素，跟着屏幕刷新率（120Hz）画是白费电
  static const _frameGap = Duration(milliseconds: 41);

  bool get _animate =>
      widget.active && widget.running && widget.history.up.length > 1 && !MediaQuery.disableAnimationsOf(context);

  void _onTick(Duration elapsed) {
    if (elapsed - _lastFrame < _frameGap) return;
    _lastFrame = elapsed;
    _repaint.tick();
  }

  void _syncTicker() {
    if (_animate) {
      if (!_ticker.isActive) {
        _lastFrame = Duration.zero;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _SpeedChart old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.infinite,
    painter: _SpeedPainter(
      history: widget.history,
      motion: _motion,
      animate: _animate,
      repaint: _repaint,
      upColor: widget.upColor,
      downColor: widget.downColor,
      idleColor: widget.idleColor,
      running: widget.running,
      fill: widget.fill,
    ),
  );
}

class _Repaint extends ChangeNotifier {
  void tick() => notifyListeners();
}

/// 折线滚动的帧间状态：上一个样本什么时候到的、样本间隔多长、纵轴最大值现在显示到多少。只在绘制时读写。
class _ChartMotion {
  int? _lastSequence;
  DateTime? _lastArrival;

  /// 样本间隔的估计（平滑过的实际间隔，夹在 0.5–3 秒）：轮询偶尔快慢一点，线头不会顿。
  double _interval = 1;
  double _shownMax = 0;
  DateTime? _lastFrame;

  /// 返回（线头进度 0–1，纵轴最大值）。进度：0 = 最新的点刚到，1 = 已画到最新点。
  (double, double) advance(int sequence, DateTime now, double targetMax, {required bool animate}) {
    if (sequence != _lastSequence) {
      final last = _lastArrival;
      if (_lastSequence != null && last != null) {
        final gap = now.difference(last).inMicroseconds / 1e6;
        if (gap > 0.2 && gap < 5) _interval = (_interval * 0.7 + gap * 0.3).clamp(0.5, 3.0);
      }
      _lastSequence = sequence;
      _lastArrival = now;
    }
    final dt = _lastFrame == null ? 0.0 : now.difference(_lastFrame!).inMicroseconds / 1e6;
    _lastFrame = now;
    if (!animate || _shownMax <= 0) {
      _shownMax = targetMax;
      return (1, targetMax);
    }
    _shownMax += (targetMax - _shownMax) * (dt * 4).clamp(0.0, 1.0);
    final phase = (now.difference(_lastArrival!).inMicroseconds / 1e6 / _interval).clamp(0.0, 1.0);
    return (phase, _shownMax);
  }
}

class _SpeedPainter extends CustomPainter {
  _SpeedPainter({
    required this.history,
    required this.motion,
    required this.animate,
    required Listenable repaint,
    required this.upColor,
    required this.downColor,
    required this.idleColor,
    required this.running,
    required this.fill,
  }) : super(repaint: repaint);

  final SpeedHistoryState history;
  final _ChartMotion motion;
  final bool animate;
  final Color upColor, downColor, idleColor;
  final bool running;
  final bool fill;

  static const _capacity = SpeedHistoryBuffer.capacity;

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
    final up = history.up, down = history.down;
    final count = up.length;
    if (count < 2) return;
    final targetMax = [...up, ...down].fold<double>(0, (m, v) => v > m ? v : m);
    final (phase, maxV) = motion.advance(history.sequence, DateTime.now(), targetMax <= 0 ? 1 : targetMax, animate: animate);
    // 上下各留 2：线宽 2，贴着顶 / 底会被裁掉一半
    final scale = (size.height - 4) * 0.9 / maxV;
    double y(double v) => size.height - 2 - (v * scale).clamp(0.0, size.height - 4);

    // 一屏 capacity − 2 格。位置按样本的绝对序号算（攒满 60 个之后下标整体前移，绝对序号不会）：
    // 线头在序号 head = 最新序号 − 1 + phase 处，线头超过一屏才整体左移。
    final step = size.width / (_capacity - 2);
    final latest = (history.sequence > count ? history.sequence : count) - 1.0;
    final first = latest - (count - 1);
    final head = latest - 1 + phase;
    final shift = head - (_capacity - 2) > 0 ? head - (_capacity - 2) : 0.0;

    List<Offset> points(List<double> data) {
      final out = <Offset>[];
      for (var i = 0; i < count - 1; i++) {
        final x = (first + i - shift) * step;
        if (x < -step) continue; // 左边缘外多留一个点，线不在边上断开
        out.add(Offset(x, y(data[i])));
      }
      final previous = data[count - 2], newest = data[count - 1];
      out.add(Offset((head - shift) * step, y(previous + (newest - previous) * phase)));
      return out;
    }

    void line(List<double> data, Color color, {required bool fill}) {
      final pts = points(data);
      if (pts.length < 2) return;
      final path = _smooth(pts);
      if (fill) {
        final area = Path.from(path)
          ..lineTo(pts.last.dx, size.height)
          ..lineTo(pts.first.dx, size.height)
          ..close();
        canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.10));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    line(down, downColor, fill: fill);
    line(up, upColor, fill: false);
  }

  /// 经各点的中点做二次曲线：拐角变圆，又不会冲过数据点（曲线落在控制点的凸包里，不会低于基线）。
  static Path _smooth(List<Offset> pts) {
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    if (pts.length == 2) return path..lineTo(pts[1].dx, pts[1].dy);
    for (var i = 1; i < pts.length - 1; i++) {
      final mid = Offset((pts[i].dx + pts[i + 1].dx) / 2, (pts[i].dy + pts[i + 1].dy) / 2);
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    return path..lineTo(pts.last.dx, pts.last.dy);
  }

  @override
  bool shouldRepaint(covariant _SpeedPainter old) =>
      old.history != history ||
      old.animate != animate ||
      old.running != running ||
      old.fill != fill ||
      old.upColor != upColor ||
      old.downColor != downColor ||
      old.idleColor != idleColor;
}
