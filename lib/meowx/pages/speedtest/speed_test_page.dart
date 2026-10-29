import '../../theme/card_surface.dart';
import 'dart:async';
import 'dart:math' as math;

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
import '../../theme/button_fill.dart';
import '../../theme/haptics.dart';
import '../../theme/page_title.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../me/me_kit.dart';
import '../proxies/proxies_page.dart' show allLeafProxies;
import 'speed_test_history_page.dart';
import 'speed_test_share.dart';

/// 网络测速（点首页网速卡打开；与 iOS / macOS 同一套）：选测速源、单 / 多线程、测速节点（节点或直连，不能选代理组），
/// 测延迟 → 下载 → 上传。测完 / 失败记一条测速记录（右上角「记录」）。测在 Go 核心里跑、经所选节点直连测速服务器（不经分流规则），见 core/meow_speedtest.go。
/// 测完之后「记录」左边多一个按钮直接分享这次的结果（同记录详情页的「分享」/「保存分享图」）。离开页面即停止。
class SpeedTestPage extends ConsumerStatefulWidget {
  const SpeedTestPage({super.key, this.controller, this.saveFile, this.shareFile, this.systemShare});

  /// 测试里换成假的；缺省用全局那一份
  final SpeedTestController? controller;

  /// 分享这次结果：测试里换成假的，缺省走平台（见 [SpeedTestShareAction]）
  final SpeedTestSaveFile? saveFile;
  final SpeedTestShareFile? shareFile;
  final bool? systemShare;

  @override
  ConsumerState<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends ConsumerState<SpeedTestPage> {
  late final SpeedTestController c = widget.controller ?? speedTestController;
  late final share = SpeedTestShareAction(
    saveFile: widget.saveFile,
    shareFile: widget.shareFile,
    systemShare: widget.systemShare,
  );

  /// 正在生成 / 分享：页头按钮转圈、不响应
  bool _sharing = false;

  Future<void> _share(SpeedTestRecord record) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await share.run(context, record);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

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
        // 测的时候节点行写实际在测的节点（核心回的 via）：主组是 url-test / fallback 时测速中途组可能换了节点，缺省推算的会跟着变
        final shown = running ? (c.progress.via ?? node) : node;
        final canStart = connected && node != null;
        final last = c.history.records.firstOrNull;
        // 这次刚测完的那条（还没测过 / 在测 / 停掉 / 失败 / 被删了都没有）：不画，不画成禁用
        final shareable = c.shareableRecord;
        return MeSubPage.list(
          title: '网络测速',
          actions: [
            if (shareable != null && SpeedTestShareImage.canShare(shareable))
              RoundGlassButton(
                icon: share.icon,
                tooltip: share.label,
                busy: _sharing,
                onTap: () => _share(shareable),
              ),
            RoundGlassButton(
              icon: Icons.history_rounded,
              tooltip: '测速记录',
              onTap: () => BaseNavigator.push(context, SpeedTestHistoryPage(controller: c)),
            ),
          ],
          children: [
            MeowCard(
              padding: const EdgeInsets.all(18),
              radius: BorderRadius.circular(24),
              child: Column(
                children: [
                  // 测速节点 + 出口（ASN · 运营商 · IP）；测的时候不能换
                  _NodePicker(
                    node: shown,
                    nodes: nodes,
                    onPicked: c.setNode,
                    enabled: !running,
                    exit: c.progress.via == shown ? c.progress : null,
                  ),
                  const SizedBox(height: 6),
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
                  // 停止的震动放在按钮上：离开页面（dispose）也会调 stop，那时不该震；开始的在 c.start 里
                  onTap: () {
                    if (running) {
                      MeowHaptics.tap();
                      c.stop();
                    } else {
                      _requestStart(node!);
                    }
                  },
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
                child: MeowCard(
                  padding: const EdgeInsets.all(16),
                  radius: BorderRadius.circular(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label(mm, '测速源'),
                      _SourcePicker(value: c.source, onChanged: c.setSource),
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
                    ],
                  ),
                ),
              ),
            ),
            MeowCardMaterial(
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
              '（Google、Microsoft 只测下载）；多线程同时开 ${SpeedTestController.multiConnections} 条连接。数据边收边丢，但会照实消耗流量。',
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
    // 服务器 · 经由 一行、已用 一行，各自不折行：以前三段拼成一句，窄屏上「已用」涨到某个数就折成两行、码表卡跟着上下跳
    final parts = [
      if (p.server != null) '服务器 ${p.server}',
      if (p.via != null) '经由 ${speedTestDisplayName(p.via!)}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(parts.join(' · '), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        const SizedBox(height: 2),
        // 从开测起就占着这一行（没用量时透明），数出来不再撑高；本机网络取到了写在前面「Wi-Fi · 已用 …」
        Opacity(
          opacity: p.bytesUsed > 0 ? 1 : 0,
          child: Text('${c.network == null ? '' : '${c.network} · '}已用 ${fmtSize(p.bytesUsed)}',
              maxLines: 1, style: style.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ],
    );
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

/// 测速源：五段一排在手机宽度上放不下（每段约 55，「Cloudflare」「Speedtest」会被截），分两排——只测下载的
/// Google / Microsoft 一排、Apple / Speedtest / Cloudflare 一排，滑块只画在选中的那一排。选中项换排时两排都重建
/// （key 跟着变），滑块直接落在新的段上，不从那一排上一次的位置滑过来。
class _SourcePicker extends StatelessWidget {
  const _SourcePicker({required this.value, required this.onChanged});
  final SpeedTestSource value;
  final ValueChanged<SpeedTestSource> onChanged;

  static const _rows = [
    [SpeedTestSource.google, SpeedTestSource.microsoft],
    [SpeedTestSource.apple, SpeedTestSource.speedtest, SpeedTestSource.cloudflare],
  ];

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (i, row) in _rows.indexed) ...[
        if (i > 0) const SizedBox(height: 6),
        MeowSegment<SpeedTestSource>(
          key: ValueKey((i, row.contains(value))),
          items: [for (final s in row) (s, s.title)],
          value: value,
          onChanged: onChanged,
          height: 38,
          fontSize: 13,
          onCard: true,
        ),
      ],
    ],
  );
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
        color: mm.buttonFill(running ? MeowButtonFill.plain : MeowButtonFill.prominent),
        shape: StadiumBorder(side: mm.buttonSide),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: SizedBox(
            height: 50,
            width: double.infinity,
            child: Center(
              child: Text(
                running ? '停止' : '开始测速',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: running ? mm.t1 : mm.onProminent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 测速节点（码表上方那一行）：名字下面一行是出口「AS2516 KDDI · 203.0.113.8」（测速时查到才有；测速中这一行一直占着，
/// 查不到写「未查到出口」——查询失败时这一行一收，下面的码表会在测速中途往上跳）；
/// 点开底部面板选（最上面固定一行「直连」，下面是节点），测的时候不能换。
class _NodePicker extends StatelessWidget {
  const _NodePicker({required this.node, required this.nodes, required this.onPicked, this.enabled = true, this.exit});
  final String? node;
  final List<String> nodes;
  final ValueChanged<String> onPicked;
  final bool enabled;

  /// 这个节点的测速进度（取其中的出口）；不是这个节点测的传 null
  final SpeedTestProgress? exit;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final p = exit;
    final pending = p != null && p.isRunning && p.exitPending;
    final found = p != null && SpeedTestExitLine.visible(p.exit, pending: pending);
    final showExit = p != null && (found || p.isRunning);
    return Material(
      color: mm.card2,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? () => _pick(context) : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          // 出口两行（ASN + 运营商、IP）占满整行宽度，「更换」放在节点名那一行（同 iOS）：挤在一行时运营商名只剩一半
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      node == null ? '没有节点' : speedTestDisplayName(node!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: node == null ? mm.t2 : mm.t1),
                    ),
                  ),
                  if (enabled) ...[
                    const SizedBox(width: 8),
                    Text('更换', style: TextStyle(fontSize: 13, color: mm.t2)),
                    const SizedBox(width: 2),
                    MeowChipChevron(color: mm.t2),
                  ],
                ],
              ),
              if (showExit) ...[
                const SizedBox(height: 4),
                if (found)
                  SpeedTestExitLine(exit: p.exit, pending: pending)
                else
                  Stack(
                    alignment: AlignmentDirectional.topStart,
                    children: [
                      // 看不见的「查询出口…」只用来撑高：两种状态一样高（它带 ASN 小标签与留空的第二行），换过来时码表一点不动
                      const Visibility(
                        visible: false,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: SpeedTestExitLine(exit: null, pending: true),
                      ),
                      Text('未查到出口', maxLines: 1, style: TextStyle(fontSize: 12, color: mm.t2)),
                    ],
                  ),
              ],
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
    return MeowCardMaterial(
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

/// 读数区（设计稿 Design/ui-redesign/speedtest-gauge-preview.html「方案 A · 指针码表」）：270° 指针码表 + 表盘下方的大号 Mbps 与阶段，
/// 下面是延迟 / 下载 / 上传三格（带峰值）与下载 / 上传曲线。下载紫、上传玫红（同网速卡），测完阶段字是绿的。
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
      'done' => mm.good,
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
    final transferring = p.phase == 'download' || p.phase == 'upload';
    return Column(
      children: [
        SpeedTestDial(
          // 指针只在下载 / 上传时指着当前速度，其余时候回到 0（测完的平均值在数字和三格里）
          mbps: transferring ? p.currentMbps : 0,
          scale: speedGaugeTiers[speedGaugeTierFor(p)],
          color: p.phase == 'upload' ? mm.accent : mm.down,
          value: big == null ? '0' : fmtMbps(big),
          dimmed: big == null,
          phase: title,
          phaseColor: tint,
        ),
        const SizedBox(height: 4),
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
        const SizedBox(height: 10),
        // 曲线测速时逐帧重画，单独一层：不带着码表和三格一起重画
        RepaintBoundary(
          child: SizedBox(
            height: 56,
            child: SpeedTestChart(
              download: p.downloadSamples,
              upload: p.uploadSamples,
              animating: p.isRunning,
              downColor: mm.down,
              upColor: mm.accent,
              baseColor: mm.line,
            ),
          ),
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

/// 码表各档量程（Mbps，按最大值从小到大）：每档刻度等距、段内线性（低速段看得清）。同 Speedtest 动态变——起步最大 500，
/// 测到的速率超过当前最大值就换到下一档（1000 / 2500 / 5000 / 10000），一次测速里只升不降。同 iOS 的 `SpeedGaugeScale`。
const speedGaugeTiers = <List<double>>[
  [0, 5, 10, 50, 100, 250, 500],
  [0, 5, 10, 50, 100, 250, 500, 1000],
  [0, 10, 50, 100, 250, 500, 1000, 2500],
  [0, 50, 100, 250, 500, 1000, 2500, 5000],
  [0, 100, 250, 500, 1000, 2500, 5000, 10000],
];

/// 装得下 [mbps] 的最小一档（不小于 [atLeast]）
int speedGaugeTier(double mbps, {int atLeast = 0}) {
  var index = atLeast.clamp(0, speedGaugeTiers.length - 1);
  while (index < speedGaugeTiers.length - 1 && mbps > speedGaugeTiers[index].last) {
    index++;
  }
  return index;
}

/// 这一次测速该用哪档：按这次测到过的最高速率（曲线样本、峰值、当前值）定，所以只升不降；新的一次测速样本清空，回到 500
int speedGaugeTierFor(SpeedTestProgress p) {
  var top = p.currentMbps;
  for (final v in [...p.downloadSamples, ...p.uploadSamples, ?p.downloadPeakMbps, ?p.uploadPeakMbps]) {
    if (v > top) top = v;
  }
  return speedGaugeTier(top);
}

/// 速度 → 刻度位置 0…1（超过最大值停在 1）
double speedGaugePosition(double mbps, [List<double> scale = const [0, 5, 10, 50, 100, 250, 500]]) {
  if (!(mbps > 0)) return 0;
  final s = scale;
  for (var i = 1; i < s.length; i++) {
    if (mbps <= s[i]) return (i - 1 + (mbps - s[i - 1]) / (s[i] - s[i - 1])) / (s.length - 1);
  }
  return 1;
}

/// 指针的帧间状态（纯逻辑，单测直接测它）：在刻度位置上做一个略欠阻尼的弹簧（阻尼比约 0.7，过冲几个百分点），
/// 进度每 300ms 才来一个值，指针在两次之间一直平滑地追过去、带一点弹簧感；按位置而不是按 Mbps 追，低速段的变化一样看得出来。
class SpeedGaugeMotion {
  static const stiffness = 60.0, damping = 11.0;

  /// 当前显示的位置（0…1）与速度
  double position = 0, velocity = 0;

  bool settledAt(double target) => (position - target).abs() < 0.0005 && velocity.abs() < 0.002;

  /// 往 [target] 走 [dt] 秒（大步长拆成小步积分，免得掉帧时弹簧发散）
  void advance(double target, double dt) {
    var left = dt;
    while (left > 0) {
      final h = left > 1 / 120 ? 1 / 120 : left;
      velocity += (stiffness * (target - position) - damping * velocity) * h;
      position += velocity * h;
      left -= h;
    }
    if (position < 0) {
      position = 0;
      if (velocity < 0) velocity = 0;
    } else if (position > 1) {
      position = 1;
      if (velocity > 0) velocity = 0;
    }
    if (settledAt(target)) jump(target);
  }

  void jump(double target) {
    position = target;
    velocity = 0;
  }
}

/// 270° 指针码表（起点 135°，顺时针扫 270°）：粗轨道 + 走过的弧段着色 + 墨色指针；刻度数字在弧外（放在弧内会被大数字压住），
/// 大数字与阶段在弧内两脚之间。按 300×266 的画板画，窄屏等比缩小。同 iOS 的 `SpeedTestDial`。
///
/// 性能：表盘（轨道 / 刻度 / 刻度字）与指针分两层，指针一层单独 RepaintBoundary；指针只在没追上目标时才按约 60 帧重画
/// （用定时器而不是 Ticker，同首页网速卡的理由），追上了、页面被盖住（TickerMode 关）、App 在后台、系统关了动画都不要帧。
class SpeedTestDial extends StatefulWidget {
  const SpeedTestDial({
    super.key,
    required this.mbps,
    required this.color,
    required this.value,
    required this.phase,
    required this.phaseColor,
    this.dimmed = false,
    this.scale = const [0, 5, 10, 50, 100, 250, 500],
  });

  /// 指针指的速度
  final double mbps;

  /// 当前量程的刻度（[speedGaugeTiers] 里的一档）
  final List<double> scale;

  /// 走过的弧段的颜色（下载紫 / 上传玫红）
  final Color color;

  /// 表盘下方的大数字
  final String value;

  /// 没有读数（准备中 / 没测过）：数字用浅色
  final bool dimmed;

  final String phase;
  final Color phaseColor;

  // 三行文字的行高写死，多留几 pt，免得中文回落字体行高大时阶段字被裁掉
  static const width = 300.0, height = 270.0;
  static const center = Offset(150, 134);
  static const radius = 104.0, arcWidth = 20.0, startDeg = 135.0, sweepDeg = 270.0;

  @override
  State<SpeedTestDial> createState() => SpeedTestDialState();
}

class SpeedTestDialState extends State<SpeedTestDial> with WidgetsBindingObserver {
  final motion = SpeedGaugeMotion();
  final _repaint = _DialRepaint();
  Timer? _timer;
  bool _resumed = true;

  static const _frameGap = Duration(milliseconds: 16);

  /// 指针正在按帧走（测试看它）
  @visibleForTesting
  bool get animating => _timer != null;

  double get _target => speedGaugePosition(widget.mbps, widget.scale);

  bool get _canAnimate => _resumed && TickerMode.valuesOf(context).enabled && !MediaQuery.disableAnimationsOf(context);

  /// inactive 也看得见（桌面窗口失焦、安卓拉下通知栏 / 分屏里焦点在另一侧），照常走；
  /// 只有 hidden / paused / detached 才停（口径同动态页的 connPollingPaused）
  static bool _visible(AppLifecycleState? s) =>
      s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed = _visible(WidgetsBinding.instance.lifecycleState);
    motion.jump(_target);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SpeedTestDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = _visible(state);
    _sync();
  }

  void _sync() {
    final target = _target;
    if (!_canAnimate) {
      _stop();
      if (!motion.settledAt(target)) {
        motion.jump(target);
        _repaint.tick();
      }
      return;
    }
    if (!motion.settledAt(target)) _timer ??= Timer.periodic(_frameGap, (_) => _onTick());
  }

  void _onTick() {
    final target = _target;
    motion.advance(target, _frameGap.inMicroseconds / 1e6);
    _repaint.tick();
    if (motion.settledAt(target)) _stop();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    const size = Size(SpeedTestDial.width, SpeedTestDial.height);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: SpeedTestDial.width,
        height: SpeedTestDial.height,
        child: Stack(
          children: [
            CustomPaint(
              size: size,
              painter: _DialFacePainter(track: mm.card2, tick: mm.t2.withValues(alpha: 0.55), scale: widget.scale),
            ),
            RepaintBoundary(
              child: CustomPaint(
                size: size,
                painter: _DialNeedlePainter(
                  motion: motion,
                  repaint: _repaint,
                  color: widget.color,
                  ink: mm.t1,
                  dot: mm.elevSolid,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 154,
              // 码表里的字不跟系统字号放大（同表盘刻度字）：这块高度写死，按 1.4 倍放大时阶段字会被裁掉
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.0,
                child: Column(
                  children: [
                    // 两脚内侧之间的宽度：四位数自己缩小，不顶到弧线
                    SizedBox(
                      width: 124,
                      height: 61,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          widget.value,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 58,
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                            color: widget.dimmed ? mm.t2.withValues(alpha: 0.5) : mm.t1,
                            fontFamilyFallback: meowRounded,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    Text('Mbps', style: TextStyle(fontSize: 15, height: 1.25, fontWeight: FontWeight.w700, color: mm.t2)),
                    const SizedBox(height: 1),
                    Text(
                      widget.phase,
                      maxLines: 1,
                      style: TextStyle(fontSize: 15, height: 1.35, fontWeight: FontWeight.w700, color: widget.phaseColor),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialRepaint extends ChangeNotifier {
  void tick() => notifyListeners();
}

double _rad(double deg) => deg * math.pi / 180;

Offset _dialPoint(double deg, double r) =>
    SpeedTestDial.center + Offset(r * math.cos(_rad(deg)), r * math.sin(_rad(deg)));

Rect get _dialArcRect => Rect.fromCircle(center: SpeedTestDial.center, radius: SpeedTestDial.radius);

/// 表盘：轨道、刻度线、刻度字。只在配色或量程变了才重画。
class _DialFacePainter extends CustomPainter {
  _DialFacePainter({required this.track, required this.tick, required this.scale});
  final Color track, tick;
  final List<double> scale;

  @override
  void paint(Canvas canvas, Size size) {
    const r = SpeedTestDial.radius;
    canvas.drawArc(
      _dialArcRect,
      _rad(SpeedTestDial.startDeg),
      _rad(SpeedTestDial.sweepDeg),
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = SpeedTestDial.arcWidth
        ..strokeCap = StrokeCap.round,
    );
    final line = Paint()
      ..color = tick
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final n = scale.length - 1;
    for (var i = 0; i <= n; i++) {
      final deg = SpeedTestDial.startDeg + SpeedTestDial.sweepDeg * i / n;
      // 两头不画刻度线：弧线端头就是 0 与最大值，画了会挨着中间的大数字
      if (i > 0 && i < n) canvas.drawLine(_dialPoint(deg, r - 24), _dialPoint(deg, r - 17), line);
      final label = TextPainter(
        text: TextSpan(
          text: scale[i].toInt().toString(),
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: tick, fontFamilyFallback: meowRounded),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // 刻度数字在弧外
      final at = _dialPoint(deg, r + SpeedTestDial.arcWidth / 2 + 14);
      label.paint(canvas, at - Offset(label.width / 2, label.height / 2));
      label.dispose();
    }
  }

  @override
  bool shouldRepaint(_DialFacePainter old) => old.track != track || old.tick != tick || !identical(old.scale, scale);
}

/// 指针层：走过的弧段 + 指针（墨色细线 + 圆心小圆 + 白点）。指针动时按帧重画，只重画这一层。
class _DialNeedlePainter extends CustomPainter {
  _DialNeedlePainter({required this.motion, required Listenable repaint, required this.color, required this.ink, required this.dot})
    : super(repaint: repaint);
  final SpeedGaugeMotion motion;
  final Color color, ink, dot;

  @override
  void paint(Canvas canvas, Size size) {
    const c = SpeedTestDial.center, r = SpeedTestDial.radius;
    final p = motion.position.clamp(0.0, 1.0);
    final deg = SpeedTestDial.startDeg + SpeedTestDial.sweepDeg * p;
    if (p > 0.002) {
      canvas.drawArc(
        _dialArcRect,
        _rad(SpeedTestDial.startDeg),
        _rad(SpeedTestDial.sweepDeg * p),
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = SpeedTestDial.arcWidth
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawLine(
      c,
      _dialPoint(deg, r - 50),
      Paint()
        ..color = ink
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(c, 11, Paint()..color = ink);
    canvas.drawCircle(c, 4.5, Paint()..color = dot);
  }

  @override
  bool shouldRepaint(_DialNeedlePainter old) =>
      old.motion != motion || old.color != color || old.ink != ink || old.dot != dot;
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
