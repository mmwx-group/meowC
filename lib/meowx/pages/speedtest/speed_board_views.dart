import 'dart:math' as math;

import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';

import '../../state/speed_board.dart';
import '../../state/speed_test.dart';
import '../../theme/button_fill.dart';
import '../../theme/card_surface.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';

// 测速榜的几块界面（设计稿 Design/ui-redesign/speedtest-board-preview.html「客户端」一节，与 iOS / macOS 同一套）：
// ① 第一次进测速页弹的同意卡片（测速页设置里那一行点开也是它）② 测完后码表下面的「超越了 x%」条 ③ 记录详情的「测速榜」一组。
// 没同意上传的人，测速页和以前一模一样。

/// 同意卡片（底部弹出）。[fromSettings] = 从测速页设置那一行点开：多一个「重置测速榜身份」，底下的说明换成开关的规则。
/// 选了「同意并上传」/「不上传」回 true / false；划掉、点外面回 null（第一次弹的：下次进测速页再问）。
Future<bool?> showSpeedBoardSheet(BuildContext context, {bool fromSettings = false, bool? current, Future<void> Function()? onResetIdentity}) {
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.mm.bg,
    builder: (ctx) => SpeedBoardConsentSheet(fromSettings: fromSettings, current: current, onResetIdentity: onResetIdentity),
  );
}

class SpeedBoardConsentSheet extends StatelessWidget {
  const SpeedBoardConsentSheet({super.key, this.fromSettings = false, this.current, this.onResetIdentity});
  final bool fromSettings;

  /// 现在的选择（从设置点开时，选中的那个按钮是实心的）
  final bool? current;
  final Future<void> Function()? onResetIdentity;

  static const yes = [
    '速率、延迟、测速源与线程、网络类型（Wi-Fi / 5G…）、节点协议（VLESS、Hysteria2…）',
    '出口所属的服务商、ASN 与地区（服务端按来源 IP 判断）',
  ];
  static const no = ['不传节点名、订阅、主控地址和账号', '直连测速时不保存你的 IP，只记运营商'];

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final body = TextStyle(fontSize: 13, height: 1.45, color: mm.t2);
    Widget item(String mark, Color color, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 18, child: Text(mark, style: TextStyle(fontSize: 13, height: 1.45, fontWeight: FontWeight.w900, color: color))),
          Expanded(child: Text(text, style: body.copyWith(color: mm.t1))),
        ],
      ),
    );
    final agreeFirst = !fromSettings || current != false;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            fromSettings ? 'MeowX 测速榜' : '参与 MeowX 测速榜？',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: mm.t1),
          ),
          const SizedBox(height: 6),
          Text('测完后把结果上传到 MeowX 测速榜，看看你超越了多少人，并能把结果做成链接分享。', style: body),
          const SizedBox(height: 12),
          MeowCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            radius: BorderRadius.circular(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final t in yes) item('✓', mm.good, t),
                for (final t in no) item('✕', mm.accent, t),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SheetButton(
            label: '同意并上传',
            prominent: agreeFirst,
            onTap: () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: 8),
          _SheetButton(
            label: '不上传',
            prominent: !agreeFirst,
            onTap: () => Navigator.of(context).pop(false),
          ),
          const SizedBox(height: 10),
          Text(
            fromSettings
                ? '只上传之后测完的结果，以前的记录不补传（可以在记录详情里单条上传）；失败的、中途停掉的一律不传。'
                : '之后可在测速页「设置」里更改',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: mm.t2),
          ),
          if (fromSettings && onResetIdentity != null) ...[
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: () => _confirmReset(context),
                child: Text('重置测速榜身份', style: TextStyle(fontSize: 13, color: mm.accent)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final mm = context.mm;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置测速榜身份？'),
        content: const Text('换一个新的本机随机 ID（只用于去重与限流）。已经上传的结果不受影响，本机记录里照样能从测速榜删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('重置', style: TextStyle(color: mm.accent))),
        ],
      ),
    );
    if (ok == true) {
      await onResetIdentity?.call();
      globalState.showNotifier('测速榜身份已重置');
    }
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({required this.label, required this.prominent, required this.onTap});
  final String label;
  final bool prominent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Material(
      color: mm.buttonFill(prominent ? MeowButtonFill.prominent : MeowButtonFill.plain),
      shape: StadiumBorder(side: mm.buttonSide),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Text(
              label,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: prominent ? mm.onProminent : mm.t1),
            ),
          ),
        ),
      ),
    );
  }
}

/// 测速页设置卡片里的一行：「上传到测速榜」开关；点字看完整说明（同意卡片）
class SpeedBoardSettingRow extends StatelessWidget {
  const SpeedBoardSettingRow({super.key, required this.value, required this.onChanged, required this.onInfo});
  final bool value;
  final ValueChanged<bool> onChanged;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onInfo,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text('上传到测速榜', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: mm.t1)),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.info_outline_rounded, size: 15, color: mm.t2),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('超越比例、分享链接；不传节点名与订阅', style: TextStyle(fontSize: 12, color: mm.t2)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Switch(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      ],
    );
  }
}

/// 「还要等 N 分钟」：不足一分钟按一分钟
String speedBoardWaitText(Duration wait) {
  final minutes = (wait.inSeconds / 60).ceil();
  return minutes >= 60 ? '${(minutes / 60).ceil()} 小时后可重试' : '$minutes 分钟后可重试';
}

/// 测完后码表下面那一条（设计稿 ②）：超越比例 + 比较范围与样本数（点了打开测速榜）；上传中 / 失败（点了重试）/ 样本还少各有写法。
/// 这条记录没传（没同意、失败的测速）就不画。
class SpeedBoardStrip extends StatelessWidget {
  const SpeedBoardStrip({super.key, required this.entry, required this.onOpenBoard, required this.onRetry, this.now});
  final SpeedBoardEntry? entry;
  final VoidCallback onOpenBoard;
  final VoidCallback onRetry;

  /// 测试里固定时间
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    if (e == null) return const SizedBox.shrink();
    final mm = context.mm;
    final Widget lead;
    final String title;
    final String? note;
    String? go;
    VoidCallback? onTap;
    switch (e.status) {
      case SpeedBoardStatus.uploading:
        lead = SizedBox(
          width: 40,
          height: 40,
          child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: mm.accent))),
        );
        title = '正在上传到测速榜…';
        note = '传完显示超越比例';
      case SpeedBoardStatus.uploaded:
        final p = e.percentile;
        lead = p == null
            ? _IconDisc(icon: Icons.check_rounded, color: mm.accent)
            : SpeedBoardRing(value: p.value, color: mm.accent, track: mm.accent.withValues(alpha: 0.15));
        title = p == null ? '已上传到测速榜' : '超越了 ${p.value}% 的测速';
        note = p == null ? '同组样本还少，暂不给超越比例' : p.scopeLine;
        go = '测速榜 ›';
        onTap = onOpenBoard;
      case SpeedBoardStatus.failed:
        final wait = e.waitBeforeRetry(now ?? DateTime.now());
        lead = _IconDisc(icon: Icons.error_outline_rounded, color: mm.slow);
        if (!e.retryable) {
          title = '测速榜没有收下这条结果';
          note = '本机结果不受影响';
        } else if (wait != null) {
          title = '${e.error ?? '上传失败'}，${speedBoardWaitText(wait)}';
          note = '本机结果不受影响';
        } else {
          title = '上传失败，点此重试';
          note = e.error;
          onTap = onRetry;
        }
    }
    return MeowCardMaterial(
      color: mm.glass ? null : mm.soft,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              lead,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: mm.t1)),
                    if (note != null && note.isNotEmpty)
                      Text(note, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mm.t2)),
                  ],
                ),
              ),
              if (go != null) ...[
                const SizedBox(width: 8),
                Text(go, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: mm.accent)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _IconDisc extends StatelessWidget {
  const _IconDisc({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.14)),
    child: Icon(icon, size: 22, color: color),
  );
}

/// 超越比例的小圆环（40pt，环宽 5，中间是百分数）
class SpeedBoardRing extends StatelessWidget {
  const SpeedBoardRing({super.key, required this.value, required this.color, required this.track, this.size = 40});
  final int value;
  final Color color, track;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _RingPainter(value / 100, color, track),
      child: Center(
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1,
          child: Text(
            '$value%',
            style: TextStyle(
              fontSize: size * 0.28,
              fontWeight: FontWeight.w900,
              color: color,
              fontFamilyFallback: meowRounded,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.color, this.track);
  final double fraction;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 5.0;
    final rect = (Offset.zero & size).deflate(width / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    final f = fraction.clamp(0.0, 1.0);
    if (f > 0) canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * f, false, paint..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.color != color || old.track != track;
}

/// 记录详情的「测速榜」一组（设计稿 ③）：超越比例（点了打开测速榜）、服务商、网页卡片链接（点了打开、右边复制）、
/// 从测速榜删除（二次确认，只删服务端那份）；上传中 / 失败（重试）；没传过且开着上传的，给「上传这条」（只给测完的）。
class SpeedBoardRecordSection extends StatelessWidget {
  const SpeedBoardRecordSection({
    super.key,
    required this.record,
    required this.boardPage,
    required this.consent,
    required this.busy,
    required this.onOpenUrl,
    required this.onCopy,
    required this.onUpload,
    required this.onDelete,
    this.now,
  });

  final SpeedTestRecord record;

  /// 测速榜页面（「超越 82% ›」点了打开；联调地址时是本机那台）
  final String boardPage;

  /// 开着「上传到测速榜」
  final bool consent;

  /// 正在上传 / 删除
  final bool busy;
  final ValueChanged<String> onOpenUrl;
  final ValueChanged<String> onCopy;
  final VoidCallback onUpload;

  /// 已经确认过了，真去删
  final VoidCallback onDelete;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final e = record.board;
    final rows = <Widget>[];
    if (e == null) {
      if (!consent || speedBoardBlocker(record) != null) return const SizedBox.shrink();
      rows.add(_row(mm, '测速榜', '还没上传', trailing: _smallButton(mm, '上传这条', busy ? null : onUpload)));
    } else {
      switch (e.status) {
        case SpeedBoardStatus.uploading:
          rows.add(_row(mm, '测速榜', '正在上传…',
              trailing: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: mm.accent))));
        case SpeedBoardStatus.failed:
          final wait = e.waitBeforeRetry(now ?? DateTime.now());
          final reason = e.retryable ? (e.error ?? '上传失败') : '测速榜没有收下这条结果';
          rows.add(_row(
            mm,
            '测速榜',
            wait == null ? reason : '$reason，${speedBoardWaitText(wait)}',
            valueColor: mm.slow,
            trailing: e.retryable && wait == null ? _smallButton(mm, '重试', busy ? null : onUpload) : null,
          ));
        case SpeedBoardStatus.uploaded:
          final p = e.percentile;
          rows.add(_row(mm, '测速榜', p == null ? '样本还少 ›' : '超越 ${p.value}% ›',
              valueColor: mm.accent, onTap: () => onOpenUrl(boardPage)));
          if (p != null) rows.add(_row(mm, '比较范围', p.scopeLine));
          if (e.provider != null) rows.add(_row(mm, '服务商', e.provider!));
          rows.add(_row(
            mm,
            '网页卡片',
            e.shortUrl ?? '',
            valueColor: mm.accent,
            onTap: () => onOpenUrl(e.url!),
            trailing: IconButton(
              tooltip: '复制链接',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.copy_rounded, size: 18, color: mm.t2),
              onPressed: () => onCopy(e.url!),
            ),
          ));
          rows.add(InkWell(
            onTap: busy ? null : () => _confirmDelete(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (busy) ...[
                    SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: mm.slow)),
                    const SizedBox(width: 8),
                  ],
                  Text('从测速榜删除', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: mm.slow)),
                ],
              ),
            ),
          ));
      }
    }
    return MeowCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      radius: BorderRadius.circular(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) Container(height: 1, color: mm.line),
            r,
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final mm = context.mm;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从测速榜删除？'),
        content: const Text('只删测速榜上的这条结果，网页卡片链接随之失效；本机记录还在。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('删除', style: TextStyle(color: mm.slow))),
        ],
      ),
    );
    if (ok == true) onDelete();
  }

  Widget _smallButton(MeowTokens mm, String label, VoidCallback? onTap) => Opacity(
    opacity: onTap == null ? 0.45 : 1,
    child: Material(
      color: mm.buttonFill(MeowButtonFill.accent),
      shape: StadiumBorder(side: mm.buttonSide),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: mm.accent)),
        ),
      ),
    ),
  );

  Widget _row(MeowTokens mm, String key, String value, {Color? valueColor, Widget? trailing, VoidCallback? onTap}) => InkWell(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Text(key, style: TextStyle(fontSize: 14, color: mm.t2)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 14, color: valueColor ?? mm.t1, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      ),
    ),
  );
}
