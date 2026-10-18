import 'package:bett_box/common/navigator.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection.dart';
import '../../state/format.dart';
import '../../state/speed_test.dart';
import '../../state/status.dart';
import '../../theme/badges.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../me/me_kit.dart';
import '../proxies/proxies_page.dart' show allLeafProxies;
import 'speed_test_history_page.dart';

/// 网络测速（点首页网速卡打开；与 iOS / macOS 同一套）：选测速源、单 / 多线程、测速节点（节点或直连，不能选代理组），
/// 测延迟 → 下载 → 上传。测完 / 失败记一条测速记录（右上角「记录」）。测在 Go 核心里跑、经所选节点直连测速服务器（不经分流规则），见 core/meow_speedtest.go。
/// 离开页面即停止。
class SpeedTestPage extends ConsumerStatefulWidget {
  const SpeedTestPage({super.key, this.controller});

  /// 测试里换成假的；缺省用全局那一份
  final SpeedTestController? controller;

  @override
  ConsumerState<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends ConsumerState<SpeedTestPage> {
  late final SpeedTestController c = widget.controller ?? speedTestController;

  @override
  void initState() {
    super.initState();
    c.load();
  }

  @override
  void dispose() {
    c.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final connected = ref.watch(isRunningProvider);
    final groups = ref.watch(currentGroupsStateProvider).value;
    // 只列真正的节点：内置的 DIRECT / REJECT / PASS 不算（同 iOS）
    final nodes = [for (final p in allLeafProxies(groups)) if (builtinSubtitle(p.name) == null) p.name];
    final exitLeaf = ref.watch(currentNodeProvider)?.leaf ?? '';
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.history]),
      builder: (context, _) {
        // 选过的节点换订阅后不在了就回到缺省：首页当前出口实际在用的节点；直连总有效
        final node = (c.node != null && (c.node == kSpeedTestDirect || nodes.contains(c.node)))
            ? c.node
            : (nodes.contains(exitLeaf) ? exitLeaf : nodes.firstOrNull);
        final running = c.isRunning;
        final canStart = connected && node != null;
        final last = c.history.records.firstOrNull;
        return MeSubPage.list(
          title: '网络测速',
          actions: [
            RoundGlassButton(
              icon: Icons.history_rounded,
              tooltip: '测速记录',
              onTap: () => BaseNavigator.push(context, SpeedTestHistoryPage(controller: c)),
            ),
          ],
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(24)),
              child: Column(
                children: [
                  SpeedTestGauge(progress: c.progress),
                  const SizedBox(height: 10),
                  _infoLine(mm),
                ],
              ),
            ),
            Column(
              children: [
                _StartButton(
                  running: running,
                  enabled: running || canStart,
                  onTap: () => running ? c.stop() : _requestStart(node!),
                ),
                if (!connected) ...[
                  const SizedBox(height: 6),
                  Text('先连接，测的是经节点出去的速度', style: TextStyle(fontSize: 12, color: mm.t2)),
                ],
              ],
            ),
            if (!running && last != null) _LastResult(controller: c, record: last),
            IgnorePointer(
              ignoring: running,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: running ? 0.5 : 1,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: mm.elev, borderRadius: BorderRadius.circular(18)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label(mm, '测速源'),
                      MeowSegment<SpeedTestSource>(
                        items: [for (final s in SpeedTestSource.values) (s, s.title)],
                        value: c.source,
                        onChanged: c.setSource,
                        height: 38,
                        fontSize: 13,
                        onCard: true,
                      ),
                      const SizedBox(height: 12),
                      _label(mm, '线程'),
                      MeowSegment<bool>(
                        items: const [(false, '单线程'), (true, '多线程（${SpeedTestController.multiConnections}）')],
                        value: c.multiThread,
                        onChanged: c.setMultiThread,
                        height: 38,
                        fontSize: 13,
                        onCard: true,
                      ),
                      const SizedBox(height: 12),
                      _label(mm, '测速节点'),
                      _NodePicker(node: node, nodes: nodes, onPicked: c.setNode),
                    ],
                  ),
                ),
              ),
            ),
            Material(
              color: mm.elev,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => globalState.openUrl(SpeedTestController.webUrl),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.public_rounded, size: 20, color: mm.accent),
                      const SizedBox(width: 10),
                      Expanded(child: Text('在浏览器打开网页测速', style: TextStyle(fontSize: 15, color: mm.t1))),
                      Icon(Icons.north_east_rounded, size: 16, color: mm.t2),
                    ],
                  ),
                ),
              ),
            ),
            const MeCaption(
              '测速经所选节点直接连测速服务器，不经分流规则（只能选节点或直连，不能选代理组；直连测的是本机网络）。先测延迟，再下载、上传各 10 秒'
              '（Google 只测下载）；多线程同时开 ${SpeedTestController.multiConnections} 条连接。数据边收边丢，但会照实消耗流量。',
            ),
          ],
        );
      },
    );
  }

  Widget _label(MeowTokens mm, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mm.t2)),
  );

  Widget _infoLine(MeowTokens mm) {
    final p = c.progress;
    final style = TextStyle(fontSize: 12, color: mm.t2);
    if (c.message != null) return Text(c.message!, style: style.copyWith(color: mm.slow));
    if (p.phase == 'failed' && p.error != null) {
      return Text(p.error!, textAlign: TextAlign.center, style: style.copyWith(color: mm.slow));
    }
    final parts = [
      if (p.server != null) '服务器 ${p.server}',
      if (p.via != null) '经由 ${speedTestDisplayName(p.via!)}',
      if (p.bytesUsed > 0) '已用 ${fmtSize(p.bytesUsed)}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(parts.join(' · '), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: style);
  }

  /// 按流量计费的网络（蜂窝）先确认一次
  Future<void> _requestStart(String node) async {
    final net = await Connectivity().checkConnectivity();
    if (!mounted) return;
    if (net.contains(ConnectivityResult.mobile)) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('当前是移动数据网络'),
          content: const Text('测速会在 10–20 秒里尽量跑满带宽，可能消耗数百 MB 流量。'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('继续测速')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    c.start(node);
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({required this.running, required this.enabled, required this.onTap});
  final bool running, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: running ? mm.elev : mm.t1,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: SizedBox(
            height: 50,
            width: double.infinity,
            child: Center(
              child: Text(
                running ? '停止' : '开始测速',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: running ? mm.t1 : mm.bg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 测速节点：点开底部面板选（最上面固定一行「直连」，下面是节点）。
class _NodePicker extends StatelessWidget {
  const _NodePicker({required this.node, required this.nodes, required this.onPicked});
  final String? node;
  final List<String> nodes;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Material(
      color: mm.bg,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _pick(context),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  node == null ? '没有节点' : speedTestDisplayName(node!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: node == null ? mm.t2 : mm.t1),
                ),
              ),
              Icon(Icons.unfold_more_rounded, size: 18, color: mm.t2),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.mm.bg,
      builder: (ctx) {
        final mm = ctx.mm;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(12, 0, 12, 16 + MediaQuery.paddingOf(ctx).bottom),
            // 0 = 直连，1 = 「节点」小标题，之后是节点
            itemCount: nodes.length + 2,
            itemBuilder: (_, i) {
              if (i == 0) {
                final selected = node == kSpeedTestDirect;
                return ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: selected ? mm.soft : null,
                  leading: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(color: mm.soft, borderRadius: BorderRadius.circular(9)),
                    child: Icon(Icons.north_east_rounded, size: 16, color: mm.accent),
                  ),
                  title: Text('直连',
                      style: TextStyle(color: selected ? mm.accent : mm.t1, fontWeight: selected ? FontWeight.w600 : null)),
                  subtitle: Text('不经节点，测本机网络（DIRECT）', style: TextStyle(fontSize: 12, color: mm.t2)),
                  onTap: () => Navigator.of(ctx).pop(kSpeedTestDirect),
                );
              }
              if (i == 1) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('节点', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: mm.t2)),
                );
              }
              final name = nodes[i - 2];
              final selected = name == node;
              return ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: selected ? mm.soft : null,
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: selected ? mm.accent : mm.t1, fontWeight: selected ? FontWeight.w600 : null)),
                onTap: () => Navigator.of(ctx).pop(name),
              );
            },
          ),
        );
      },
    );
    if (picked != null) onPicked(picked);
  }
}

/// 「上次结果」：最近一条记录的摘要，点了直接进这条的详情。
class _LastResult extends StatelessWidget {
  const _LastResult({required this.controller, required this.record});
  final SpeedTestController controller;
  final SpeedTestRecord record;

  String get _summary {
    final r = record;
    if (r.error != null) return '失败：${r.error}';
    return [
      if (r.downloadMbps != null) '↓ ${fmtRecordMbps(r.downloadMbps)} Mbps',
      if (r.uploadMbps != null) '↑ ${fmtRecordMbps(r.uploadMbps)}',
      if (r.latencyMs != null) '${r.latencyMs} ms',
      r.timeTitle,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Material(
      color: mm.elev,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => BaseNavigator.push(context, SpeedTestRecordPage(controller: controller, id: record.id)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const IconTile(icon: Icons.history_rounded, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '上次结果 · ${record.displayName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: mm.t1),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: mm.t2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MeowChipChevron(color: mm.t2),
            ],
          ),
        ),
      ),
    );
  }
}

/// 读数区：阶段 + 大号 Mbps + 阶段进度条 + 下载 / 上传曲线 + 延迟 / 下载 / 上传三格。下载紫、上传玫红（同网速卡）。
class SpeedTestGauge extends StatelessWidget {
  const SpeedTestGauge({super.key, required this.progress});
  final SpeedTestProgress progress;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final p = progress;
    final Color tint = switch (p.phase) {
      'download' => mm.down,
      'upload' => mm.accent,
      'failed' => mm.slow,
      _ => mm.t2,
    };
    final title = switch (p.phase) {
      'preparing' => p.source == SpeedTestSource.speedtest ? '挑选测速服务器…' : '连接测速服务器…',
      'latency' => '测延迟…',
      'download' => '下载中',
      'upload' => '上传中',
      'done' => '测速完成',
      'failed' => '测速失败',
      'cancelled' => '已停止',
      _ => '准备就绪',
    };
    final double? big = switch (p.phase) {
      'download' || 'upload' => p.currentMbps,
      'done' || 'failed' || 'cancelled' => p.downloadMbps ?? p.uploadMbps,
      _ => null,
    };
    final running = p.phase == 'download' || p.phase == 'upload';
    final barValue = running ? p.phaseProgress : (p.phase == 'done' ? 1.0 : 0.0);
    return Column(
      children: [
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tint)),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              big == null ? '0' : fmtMbps(big),
              style: TextStyle(
                fontSize: 52,
                fontWeight: FontWeight.w700,
                height: 1.1,
                color: big == null ? mm.t2.withValues(alpha: 0.5) : mm.t1,
                fontFamilyFallback: meowRounded,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            Text('Mbps', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: mm.t2)),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: barValue),
            duration: const Duration(milliseconds: 300),
            builder: (_, v, _) => LinearProgressIndicator(
              value: v,
              minHeight: 4,
              backgroundColor: mm.card2,
              valueColor: AlwaysStoppedAnimation(tint),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 64,
          child: SpeedTestChart(
            download: p.downloadSamples,
            upload: p.uploadSamples,
            animating: p.isRunning,
            downColor: mm.down,
            upColor: mm.accent,
            baseColor: mm.line,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _tile(mm, '延迟', p.latencyMs?.toString(), 'ms', mm.t1),
            const SizedBox(width: 8),
            _tile(mm, '下载', p.downloadMbps == null ? null : fmtMbps(p.downloadMbps!), 'Mbps', mm.down,
                peak: p.downloadPeakMbps),
            const SizedBox(width: 8),
            _tile(mm, '上传', p.uploadMbps == null ? null : fmtMbps(p.uploadMbps!), 'Mbps', mm.accent,
                peak: p.uploadPeakMbps, note: p.source?.hasUpload == false ? '不支持' : null),
          ],
        ),
      ],
    );
  }

  Widget _tile(MeowTokens mm, String title, String? value, String unit, Color tint, {double? peak, String? note}) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: mm.card2, borderRadius: BorderRadius.circular(12)),
          child: Column(
            children: [
              Text(title, style: TextStyle(fontSize: 11, color: mm.t2)),
              // 固定字号 + 等宽数字：测速时每 300ms 一跳，以前套 FittedBox，位数一变整格就重新缩放一次，看着一直在抖、发糊
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: value ?? '—',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: value == null ? mm.t2 : tint,
                      fontFamilyFallback: meowRounded,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (value != null) TextSpan(text: ' $unit', style: TextStyle(fontSize: 10, color: mm.t2)),
                ]),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
              Text(
                note ?? (peak == null ? ' ' : '峰值 ${fmtMbps(peak)}'),
                maxLines: 1,
                style: TextStyle(fontSize: 10, color: mm.t2),
              ),
            ],
          ),
        ),
      );
}

/// 下载 / 上传两条速率曲线（每 0.25s 一格，一屏按 10 秒 = 40 格；两条共用纵轴）。
///
/// 逐帧绘制（与 iOS 的 SpeedTestChart 同一套）：进度每 0.3s 左右才拉回一批样本，直接画会一跳一跳的。测速进行中按帧重画，
/// 每条线的线头按时间往最新样本走、在相邻两个样本之间插值（速度与落后的格数成正比，落后一格时每秒 4 格），
/// 纵轴最大值约 0.25s 渐变过去。没在测就直接画全。
class SpeedTestChart extends StatefulWidget {
  const SpeedTestChart({
    super.key,
    required this.download,
    required this.upload,
    required this.animating,
    required this.downColor,
    required this.upColor,
    required this.baseColor,
  });

  final List<double> download, upload;
  final bool animating;
  final Color downColor, upColor, baseColor;

  @override
  State<SpeedTestChart> createState() => _SpeedTestChartState();
}

/// 线头的帧间状态（纯逻辑，单测直接测它）。
class SpeedTestChartMotion {
  static const samplesPerSecond = 4.0;

  double downloadHead = 0, uploadHead = 0, shownMax = 0;

  static double step(double head, int count, double dt) {
    final target = (count - 1).clamp(0, 1 << 30).toDouble();
    if (head > target) return 0;
    final next = head + samplesPerSecond * (target - head) * dt;
    return next > target ? target : next;
  }

  void advance({required int download, required int upload, required double targetMax, required double dt, required bool live}) {
    if (!live) {
      downloadHead = (download - 1).clamp(0, 1 << 30).toDouble();
      uploadHead = (upload - 1).clamp(0, 1 << 30).toDouble();
      shownMax = targetMax;
      return;
    }
    downloadHead = step(downloadHead, download, dt);
    uploadHead = step(uploadHead, upload, dt);
    shownMax = shownMax <= 0 ? targetMax : shownMax + (targetMax - shownMax) * (dt * 4).clamp(0, 1);
  }
}

class _SpeedTestChartState extends State<SpeedTestChart> with SingleTickerProviderStateMixin {
  final motion = SpeedTestChartMotion();
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;

  /// 约 30 帧：线头每秒只走几个像素，再快没有意义
  static const _frameGap = Duration(milliseconds: 33);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SpeedTestChart old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final live = widget.animating && !(WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations);
    if (live && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!live && _ticker.isActive) {
      _ticker.stop();
    }
    if (!live) _advance(0, false);
  }

  void _onTick(Duration elapsed) {
    if (elapsed - _last < _frameGap && _last != Duration.zero) return;
    final dt = _last == Duration.zero ? 0.0 : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    setState(() => _advance(dt, true));
  }

  void _advance(double dt, bool live) {
    final all = [...widget.download, ...widget.upload];
    final top = all.isEmpty ? 1.0 : all.reduce((a, b) => a > b ? a : b);
    motion.advance(download: widget.download.length, upload: widget.upload.length,
        targetMax: top < 1 ? 1 : top, dt: dt, live: live);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _SpeedTestPainter(
      download: widget.download,
      upload: widget.upload,
      downloadHead: motion.downloadHead,
      uploadHead: motion.uploadHead,
      maxValue: motion.shownMax < 1 ? 1 : motion.shownMax,
      downColor: widget.downColor,
      upColor: widget.upColor,
      baseColor: widget.baseColor,
    ),
    size: Size.infinite,
  );
}

class _SpeedTestPainter extends CustomPainter {
  _SpeedTestPainter({
    required this.download,
    required this.upload,
    required this.downloadHead,
    required this.uploadHead,
    required this.maxValue,
    required this.downColor,
    required this.upColor,
    required this.baseColor,
  });

  final List<double> download, upload;
  final double downloadHead, uploadHead, maxValue;
  final Color downColor, upColor, baseColor;

  static const slots = 40;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(Offset(0, size.height - 1), Offset(size.width, size.height - 1),
        Paint()..color = baseColor..strokeWidth = 1);
    final count = [slots, download.length, upload.length].reduce((a, b) => a > b ? a : b);
    final step = size.width / (count - 1);
    double y(double v) => size.height - 1 - (v / maxValue).clamp(0, 1) * (size.height - 4);
    void line(List<double> values, double head, Color color) {
      if (values.length < 2 || head <= 0) return;
      final whole = head.floor();
      final points = <Offset>[
        for (var i = 0; i <= whole && i < values.length; i++) Offset(i * step, y(values[i])),
      ];
      final fraction = head - whole;
      if (fraction > 0 && whole + 1 < values.length) {
        final v = values[whole] + (values[whole + 1] - values[whole]) * fraction;
        points.add(Offset(head * step, y(v)));
      }
      if (points.length < 2) return;
      final path = Path()..moveTo(points[0].dx, points[0].dy);
      if (points.length == 2) {
        path.lineTo(points[1].dx, points[1].dy);
      } else {
        for (var i = 1; i < points.length - 1; i++) {
          final mid = Offset((points[i].dx + points[i + 1].dx) / 2, (points[i].dy + points[i + 1].dy) / 2);
          path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
        }
        path.lineTo(points.last.dx, points.last.dy);
      }
      final area = Path.from(path)
        ..lineTo(points.last.dx, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.12));
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

    line(download, downloadHead, downColor);
    line(upload, uploadHead, upColor);
  }

  @override
  bool shouldRepaint(_SpeedTestPainter old) =>
      old.downloadHead != downloadHead ||
      old.uploadHead != uploadHead ||
      old.maxValue != maxValue ||
      !identical(old.download, download) ||
      !identical(old.upload, upload) ||
      old.downColor != downColor;
}
