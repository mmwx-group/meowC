import 'dart:async';

import 'package:bett_box/common/navigator.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/meow_tab.dart';
import '../../app/strings.dart';
import '../../state/format.dart';
import '../../state/speed_history.dart';
import '../../state/status.dart';
import '../../theme/m3.dart';
import '../../theme/m3_kit.dart';
import '../../theme/tokens.dart';
import '../speedtest/speed_test_page.dart';

/// 网速卡（画布稿 Main）：下载（主色）/ 上传（第三色）两列大字 + 右上角网络测速圆钮 + 近 60 秒折线 + 本次累计。
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
    this.compact = false,
    this.chartHeight,
  });

  final bool up, down, chart, dense, expand, compact;
  final double? chartHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
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
    final mm = context.mm;
    final downColor = mm.down, upColor = cs.primary;

    // 一栏（同 iOS 首页网速卡）：带色箭头 + 灰字标题 / 大字速率（单位同字号）/「会话 X」，整栏居中；
    // 放不下（窄屏 / 大字号）时速率整体缩小，不截成「12.3 M…」
    Widget rate(IconData icon, Color color, String label, int value, int session) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            fmtRate(value),
            maxLines: 1,
            style: TextStyle(
              fontSize: dense ? 24 : 26,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${S.session} ${fmtSize(session)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: MeowFont.caption,
            color: cs.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );

    final painter = _SpeedChart(
      history: history,
      active: ref.watch(meowTabProvider.select((t) => t == MeowTab.home)),
      upColor: upColor,
      downColor: downColor,
      // 未连接时画柔和基线，避免网速卡下半部分大块空洞
      idleColor: cs.outlineVariant.withValues(alpha: 0.45),
      running: running,
      fill: true,
    );
    final speedTest = Tooltip(
      message: '网络测速',
      child: Material(
        color: cs.secondaryContainer,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => BaseNavigator.push(context, const SpeedTestPage()),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.speed_rounded, size: 13, color: cs.onSecondaryContainer),
                const SizedBox(width: 3),
                Text(
                  '测速',
                  textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15),
                  style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w700, color: cs.onSecondaryContainer),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final Widget ratesWidget;
    if (compact) {
      Widget compactLine(IconData icon, Color color, String label, int value) => Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
          const SizedBox(width: 6),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                fmtRate(value),
                maxLines: 1,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ],
      );
      ratesWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '实时网速',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: cs.onSurface),
                ),
              ),
              speedTest,
            ],
          ),
          const SizedBox(height: 10),
          if (up) compactLine(Icons.arrow_upward_rounded, upColor, S.upload, last?.up.value ?? 0),
          if (up && down) const SizedBox(height: 6),
          if (down) compactLine(Icons.arrow_downward_rounded, downColor, S.download, last?.down.value ?? 0),
        ],
      );
    } else {
      // 对称两栏：顶栏左标题 + 右「测速」胶囊，下方上传/下载完全对称对齐，不再挤压右栏
      ratesWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '实时网速',
                style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              speedTest,
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (up)
                Expanded(
                  child: rate(Icons.arrow_upward_rounded, upColor, S.upload, last?.up.value ?? 0, total.up.value),
                ),
              if (up && down)
                Container(
                  width: 1,
                  height: 44,
                  margin: const EdgeInsets.only(top: 10),
                  color: cs.outlineVariant.withValues(alpha: 0.45),
                ),
              if (down)
                Expanded(
                  child: rate(Icons.arrow_downward_rounded, downColor, S.download, last?.down.value ?? 0, total.down.value),
                ),
            ],
          ),
        ],
      );
    }
    final resolvedChartHeight = chartHeight ?? (compact ? 32.0 : (dense ? 56.0 : 46.0));
    return M3Card(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MeowShape.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: (expand && chart) || compact ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 14 : 16, compact ? 12 : 12, compact ? 12 : 14, chart ? 6 : 14),
              child: ratesWidget,
            ),
            if (compact) const Spacer(),
            if (chart)
              if (expand)
                Expanded(child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 24), child: painter))
              else
                SizedBox(height: resolvedChartHeight, child: painter),
          ],
        ),
      ),
    );
  }
}

/// 近 60 秒双线：下载（主色，线宽 3，下方铺 12% 底色）在下层、上传（第三色，线宽 2.5）在上层。未连接画一条虚线。
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

class _SpeedChartState extends State<_SpeedChart> {
  Timer? _timer;
  final _repaint = _Repaint();
  final _motion = _ChartMotion();

  /// 约 24 帧：折线每秒只移几个像素。用定时器而不是 Ticker：Ticker 每个 vsync 都排一帧（高刷屏 120 次/秒），
  /// 哪怕回调里跳过重画，那一帧照样整屏合成、液态玻璃底栏跟着重跑一遍着色器；定时器只在要画时才排帧。
  static const _frameGap = Duration(milliseconds: 41);

  /// 首页不是当前页（外层 TickerMode 关着）、系统关了动画、没在跑：都不动
  bool get _animate =>
      widget.active &&
      widget.running &&
      widget.history.up.length > 1 &&
      TickerMode.valuesOf(context).enabled &&
      !MediaQuery.disableAnimationsOf(context);

  void _syncTimer() {
    if (_animate) {
      _timer ??= Timer.periodic(_frameGap, (_) => _repaint.tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _SpeedChart old) {
    super.didUpdateWidget(old);
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _repaint.dispose();
    super.dispose();
  }

  // 折线每 41ms 重画一次，单独一层：不带着网速卡的文字一起重画
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
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

    // 一屏 capacity − 4 格。位置按样本的绝对序号算（攒满 60 个之后下标整体前移，绝对序号不会）：
    // 线头在序号 head = 最新序号 − 1 + phase 处，线头超过一屏才整体左移。
    // 攒满后最老的点在左边缘外 2–3 格：平滑曲线每段只受相邻三个点影响，丢掉最老的点时变形的那一段
    // 整个在左边缘外（以前只多留一格，丢点那一下左边缘那一段曲线会跳，看着是「卡一下消失」）。
    const cells = _capacity - 4;
    final step = size.width / cells;
    final latest = (history.sequence > count ? history.sequence : count) - 1.0;
    final first = latest - (count - 1);
    final head = latest - 1 + phase;
    final shift = head - cells > 0 ? head - cells : 0.0;

    List<Offset> points(List<double> data) {
      final out = <Offset>[];
      for (var i = 0; i < count - 1; i++) {
        out.add(Offset((first + i - shift) * step, y(data[i])));
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
        final shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.24), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size);
        canvas.drawPath(area, Paint()..shader = shader);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = fill ? 3 : 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // 左边缘外的点不画出卡片；左边 24 像素渐隐，线是慢慢淡出去的，不是在边上被切断
    final bounds = Offset.zero & size;
    canvas.clipRect(bounds);
    canvas.saveLayer(bounds, Paint());
    line(down, downColor, fill: fill);
    line(up, upColor, fill: false);
    if (shift > 0) {
      // 刚开始左移时线头还贴着左边缘：渐隐在一格之内慢慢加深，不突然出现
      final fade = (24 / size.width).clamp(0.0, 0.5);
      final edge = 1 - shift.clamp(0.0, 1.0);
      canvas.drawRect(
        bounds,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = LinearGradient(
            colors: [Color.fromRGBO(0, 0, 0, edge), const Color(0xFF000000)],
            stops: [0, fade],
          ).createShader(bounds),
      );
    }
    canvas.restore();
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
