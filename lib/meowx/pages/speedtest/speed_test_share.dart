import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../../state/speed_test.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart' show BrandHead, meowRounded;
import 'speed_test_history_page.dart' show SpeedTestRecordChartPainter;

/// 测速记录的分享图（工单 #1270，与 iOS / macOS 同一份需求）：1080 × 1350 像素的 4:5 竖图，从记录详情页生成 PNG：
/// 安卓「分享」经 share_plus 弹系统分享面板（同 iOS），Windows「保存分享图」经 `picker.saveFile` 另存新档。
///
/// 配色跟着分享时 App 实际生效的外观（主题色 + 深浅，同 iOS / macOS）：传进来的 [MeowTokens] 就是 App 当前那一份
/// （`context.mm`：「我的 › 外观」的设置在当前深浅色下解析出来的）。页面底：经典 = 平涂 [MeowTokens.bg]；液态玻璃 = 底色渐层
/// （[MeowTokens.bgGradient]，方向照 [MeowTokens.bgDiagonal]），不画光斑与插画（自选的照片不能跟着分享出去）。卡片是不透明的
/// [MeowTokens.elevSolid]（经典 = 卡片色；液态玻璃 = 玻璃卡片叠在页面底上的实色），不画玻璃效果。字、强调色、下载紫、分隔线都取同一份
/// token；页头 App 图标按深浅取浅 / 深两张（同 [BrandHead]）。
/// 自上而下：页头（App 图标 + MeowX + 网络测速、右边日期时间）→ 下载主卡（大数字 + 峰值）→ 上传 / 延迟两张小卡 →
/// 速率曲线（同详情页的画法）→ 测速源 · 线程、出站、出口三行 → 页脚。出口只写 ASN / 运营商，**不写 IP**
/// （直连测速时那是用户自家的公网 IP）。不画任何可点的控件样式。
///
/// 按 450 宽的版式画、整张放大 2.4 倍（1080 / 450），字号层级同测速记录详情页；曲线卡占上下排完之后剩下的高度。
class SpeedTestShareImage {
  SpeedTestShareImage._();

  static const width = 1080;
  static const height = 1350;
  static const _scale = width / 450;

  /// 页头的 App 图标：浅色白发、深色黑发（同 [BrandHead]）
  static String iconAsset(Brightness brightness) =>
      brightness == Brightness.dark ? 'assets/images/icon_256.png' : 'assets/images/icon_light_256.png';

  /// 失败的记录不给分享
  static bool canShare(SpeedTestRecord record) => !record.failed;

  /// 「MeowX-speedtest-20261029-1432.png」
  static String fileName(SpeedTestRecord record) {
    String two(int v) => v.toString().padLeft(2, '0');
    final d = record.date;
    return 'MeowX-speedtest-${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}.png';
  }

  /// 生成 PNG；失败的记录返回 null。[tokens] / [brightness] = App 当前的配色与深浅（`context.mm` 与 `Theme.of(context).brightness`）；
  /// [textStyle] 是 App 正文的字族（含回落字族），图里的字都用它；[icon] 缺省按深浅读 [iconAsset]。
  static Future<Uint8List?> render(
    SpeedTestRecord record, {
    required MeowTokens tokens,
    required Brightness brightness,
    TextStyle? textStyle,
    ui.Image? icon,
  }) async {
    final content = SpeedTestShareContent.of(record);
    if (content == null) return null;
    final logo = icon ?? await _loadIcon(iconAsset(brightness));
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
      _SharePainter(record, content, tokens, textStyle ?? const TextStyle(), logo).paint(canvas);
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } finally {
      if (icon == null) logo?.dispose();
    }
  }

  static Future<ui.Image?> _loadIcon(String asset) async {
    try {
      final data = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null; // 读不到图标就只画字
    }
  }
}

/// 分享图上的字（纯值，单测直接看它）。
@immutable
class SpeedTestShareContent {
  const SpeedTestShareContent({
    required this.dateTime,
    required this.download,
    this.downloadPeak,
    this.upload,
    required this.uploadNote,
    this.latency,
    required this.sourceLine,
    required this.outbound,
    this.exit,
  });

  /// 「2026-10-29 14:32」
  final String dateTime;

  /// 下载平均（数字，不带单位）与「峰值 X Mbps」
  final String download;
  final String? downloadPeak;

  /// 上传平均；null = 没有（只测下载的源画「—」）。[uploadNote] 是下面那行小字：「此测速源只测下载」或「峰值 X Mbps」
  final String? upload;
  final String uploadNote;

  /// 延迟毫秒数；null = 没测到
  final String? latency;

  /// 「Microsoft · 8 线程」/「Google · 单线程」（同记录详情页的 threadsTitle）
  final String sourceLine;

  /// 节点名；直连「直连 · 本机网络」
  final String outbound;

  /// 出口「AS2516 KDDI」（只有 ASN / 运营商，不带 IP）；查不到 null
  final String? exit;

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 失败的记录返回 null
  static SpeedTestShareContent? of(SpeedTestRecord r) {
    if (r.failed) return null;
    final d = r.date;
    final hasUpload = r.source.hasUpload;
    final e = r.exit;
    final exit = e == null ? '' : [?e.asnTag, ?e.shortOrg].join(' ');
    return SpeedTestShareContent(
      dateTime: '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}',
      download: fmtRecordMbps(r.downloadMbps),
      downloadPeak: r.downloadPeakMbps == null ? null : '峰值 ${fmtRecordMbps(r.downloadPeakMbps)} Mbps',
      upload: hasUpload && r.uploadMbps != null ? fmtRecordMbps(r.uploadMbps) : null,
      uploadNote: !hasUpload
          ? '此测速源只测下载'
          : (r.uploadPeakMbps == null ? '未测' : '峰值 ${fmtRecordMbps(r.uploadPeakMbps)} Mbps'),
      latency: r.latencyMs?.toString(),
      sourceLine: '${r.source.title} · ${r.threadsTitle}',
      outbound: r.isDirect ? '直连 · 本机网络' : r.outbound,
      exit: exit.isEmpty ? null : exit,
    );
  }
}

/// 在 1080 × 1350 的画布上画（坐标按 450 宽的版式，画之前整体放大 [SpeedTestShareImage._scale]）。
class _SharePainter {
  _SharePainter(this.record, this.content, this.mm, this.base, this.icon);
  final SpeedTestRecord record;
  final SpeedTestShareContent content;
  final MeowTokens mm;
  final TextStyle base;
  final ui.Image? icon;

  static const w = 450.0, h = 1350 / SpeedTestShareImage._scale;
  static const side = 24.0;
  static const inner = w - side * 2;

  final _painters = <TextPainter>[];

  TextStyle _style(double size, Color color, {FontWeight weight = FontWeight.w400, bool rounded = false}) => base.copyWith(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: 1.2,
    fontFamilyFallback: rounded ? meowRounded : null,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// 大数字：圆体、等宽数字（同测速记录详情页）
  TextStyle _num(double size, Color color) =>
      _style(size, color, weight: FontWeight.w800, rounded: true).copyWith(height: 1.05);

  TextPainter _text(String text, TextStyle style, {double maxWidth = inner}) {
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    _painters.add(p);
    return p;
  }

  /// 卡片：不透明的实色（液态玻璃下 [MeowTokens.elev] 是半透明的，用叠好的 [MeowTokens.elevSolid]）
  void _card(Canvas canvas, Rect rect, double radius) =>
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)), Paint()..color = mm.elevSolid);

  /// 页面底：平涂 [MeowTokens.bg]；液态玻璃是底色渐层，按整张图铺（斜向 = 左上 → 右下，否则自上而下，同 App 里按整屏铺）
  Paint _page() {
    final g = mm.bgGradient;
    if (g == null) return Paint()..color = mm.bg;
    return Paint()..shader = ui.Gradient.linear(Offset.zero, mm.bgDiagonal ? const Offset(w, h) : const Offset(0, h), g);
  }

  /// 圆点 + 标题（同详情页的图例）；返回占的高度
  double _legend(Canvas canvas, Offset at, String title, Color? dot) {
    final label = _text(title, _style(13, mm.t2, weight: FontWeight.w700));
    var x = at.dx;
    if (dot != null) {
      canvas.drawCircle(Offset(x + 4, at.dy + label.height / 2), 4, Paint()..color = dot);
      x += 13;
    }
    label.paint(canvas, Offset(x, at.dy));
    return label.height;
  }

  /// 数字 + 单位（按基线对齐，单位紧跟数字），放在 [maxWidth] 宽里；返回占的高度
  double _value(Canvas canvas, Offset at, String value, TextStyle style, String? unit, double unitSize, double maxWidth) {
    final u = unit == null ? null : _text(unit, _style(unitSize, mm.t2, weight: FontWeight.w600));
    final number = _text(value, style, maxWidth: maxWidth - (u == null ? 0 : u.width + 4));
    number.paint(canvas, at);
    if (u != null) {
      final baseline = number.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      final unitBaseline = u.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      u.paint(canvas, Offset(at.dx + number.width + 4, at.dy + baseline - unitBaseline));
    }
    return number.height;
  }

  void paint(Canvas canvas) {
    canvas
      ..save()
      ..scale(SpeedTestShareImage._scale)
      ..drawRect(const Rect.fromLTWH(0, 0, w, h), _page());
    try {
      var y = _header(canvas, 24);
      y = _mainCard(canvas, y + 14);
      y = _smallCards(canvas, y + 10);
      // 底部从下往上排：页脚、信息卡；中间剩下的给曲线卡
      final footer = _text('MeowX 网络测速', _style(12, mm.t2));
      final footerTop = h - 18 - footer.height;
      footer.paint(canvas, Offset((w - footer.width) / 2, footerTop));
      final infoTop = _infoCard(canvas, footerTop - 10);
      _chartCard(canvas, Rect.fromLTRB(side, y + 10, w - side, infoTop - 10));
    } finally {
      canvas.restore();
      for (final p in _painters) {
        p.dispose();
      }
    }
  }

  /// 页头：圆角 App 图标 + 「MeowX」/「网络测速」，右边日期时间。返回底边
  double _header(Canvas canvas, double top) {
    const size = 40.0;
    final img = icon;
    final iconRect = Rect.fromLTWH(side, top, size, size);
    if (img != null) {
      canvas
        ..save()
        ..clipRRect(RRect.fromRectAndRadius(iconRect, const Radius.circular(size * 0.31)))
        ..drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          iconRect,
          Paint()..filterQuality = FilterQuality.high,
        )
        ..restore();
    }
    final x = side + size + 10;
    final date = _text(content.dateTime, _style(13, mm.t2));
    final titleWidth = w - side - date.width - 12 - x;
    final title = _text('MeowX', _style(18, mm.t1, weight: FontWeight.w800, rounded: true), maxWidth: titleWidth);
    final sub = _text('网络测速', _style(12, mm.t2), maxWidth: titleWidth);
    final textTop = top + (size - title.height - sub.height) / 2;
    title.paint(canvas, Offset(x, textTop));
    sub.paint(canvas, Offset(x, textTop + title.height));
    date.paint(canvas, Offset(w - side - date.width, top + (size - date.height) / 2));
    return top + size;
  }

  /// 下载主卡：「下载」、大数字 + Mbps、峰值。返回底边
  double _mainCard(Canvas canvas, double top) {
    const padH = 20.0, padV = 14.0;
    final numberStyle = _num(54, mm.down);
    final legendHeight = _text(' ', _style(13, mm.t2, weight: FontWeight.w700)).height;
    final numberHeight = _text('0', numberStyle).height;
    final peak = _text(content.downloadPeak ?? ' ', _style(13, mm.t2));
    final height = padV + legendHeight + 2 + numberHeight + 2 + peak.height + padV;
    _card(canvas, Rect.fromLTWH(side, top, inner, height), 24);
    var y = top + padV;
    y += _legend(canvas, Offset(side + padH, y), '下载', mm.down) + 2;
    y += _value(canvas, Offset(side + padH, y), content.download, numberStyle, 'Mbps', 18, inner - padH * 2) + 2;
    peak.paint(canvas, Offset(side + padH, y));
    return top + height;
  }

  /// 上传 / 延迟两张小卡。返回底边
  double _smallCards(Canvas canvas, double top) {
    const padH = 16.0, padV = 12.0, gap = 10.0;
    final cardWidth = (inner - gap) / 2;
    final valueHeight = _text('0', _num(30, mm.t1)).height;
    final noteHeight = _text(' ', _style(12, mm.t2)).height;
    final legendHeight = _text(' ', _style(13, mm.t2, weight: FontWeight.w700)).height;
    final height = padV + legendHeight + 2 + valueHeight + 2 + noteHeight + padV;
    final maxText = cardWidth - padH * 2;
    // 没有值（只测下载的源的上传、没测到的延迟）：次级色的「—」，不带单位
    void card(double left, String title, Color? dot, String? value, Color tint, String unit, String? sub) {
      _card(canvas, Rect.fromLTWH(left, top, cardWidth, height), 18);
      var y = top + padV;
      y += _legend(canvas, Offset(left + padH, y), title, dot) + 2;
      y += _value(canvas, Offset(left + padH, y), value ?? '—', _num(30, value == null ? mm.t2 : tint),
              value == null ? null : unit, 14, maxText) +
          2;
      if (sub != null) _text(sub, _style(12, mm.t2), maxWidth: maxText).paint(canvas, Offset(left + padH, y));
    }

    card(side, '上传', mm.accent, content.upload, mm.accent, 'Mbps', content.uploadNote);
    card(side + cardWidth + gap, '延迟', null, content.latency, mm.t1, 'ms', null);
    return top + height;
  }

  /// 速率曲线卡（下载 + 上传两条，同详情页的画法）：标题行右边是图例
  void _chartCard(Canvas canvas, Rect rect) {
    const padH = 18.0, padV = 14.0;
    _card(canvas, rect, 24);
    final title = _text('速率曲线', _style(12, mm.t2, weight: FontWeight.w600));
    title.paint(canvas, Offset(rect.left + padH, rect.top + padV));
    // 图例从右往左排：只测下载的没有上传那条
    final legends = [('下载', mm.down), if (record.uploadSamples.length > 1) ('上传', mm.accent)];
    final centerY = rect.top + padV + title.height / 2;
    var right = rect.right - padH;
    for (final (label, color) in legends.reversed) {
      final t = _text(label, _style(12, mm.t2));
      final textLeft = right - t.width;
      t.paint(canvas, Offset(textLeft, centerY - t.height / 2));
      final dot = textLeft - 5 - 4;
      canvas.drawCircle(Offset(dot, centerY), 4, Paint()..color = color);
      right = dot - 4 - 14;
    }
    final chart = Rect.fromLTRB(rect.left + padH, rect.top + padV + title.height + 8, rect.right - padH, rect.bottom - padV);
    if (chart.height <= 10) return;
    canvas
      ..save()
      ..translate(chart.left, chart.top);
    SpeedTestRecordChartPainter(record.downloadSamples, record.uploadSamples, mm.down, mm.accent, mm.line)
        .paint(canvas, chart.size);
    canvas.restore();
  }

  /// 信息卡：测速源 · 线程、出站、出口（只有 ASN / 运营商）。[bottom] 是底边，返回顶边
  double _infoCard(Canvas canvas, double bottom) {
    const padH = 18.0, padV = 3.0, rowPad = 6.5;
    final rows = [('测速源', content.sourceLine), ('出站', content.outbound), if (content.exit != null) ('出口', content.exit!)];
    final keyStyle = _style(13, mm.t2), valueStyle = _style(13, mm.t1);
    final rowHeight = _text(' ', valueStyle).height + rowPad * 2;
    final height = padV * 2 + rowHeight * rows.length;
    final top = bottom - height;
    _card(canvas, Rect.fromLTWH(side, top, inner, height), 18);
    final line = Paint()
      ..color = mm.line
      ..strokeWidth = 1;
    for (final (i, (key, value)) in rows.indexed) {
      final rowTop = top + padV + rowHeight * i;
      final k = _text(key, keyStyle);
      k.paint(canvas, Offset(side + padH, rowTop + rowPad));
      final maxValue = inner - padH * 2 - k.width - 16;
      final v = _text(value, valueStyle, maxWidth: maxValue);
      v.paint(canvas, Offset(side + inner - padH - v.width, rowTop + rowPad));
      if (i < rows.length - 1) {
        canvas.drawLine(Offset(side + padH, rowTop + rowHeight), Offset(side + inner - padH, rowTop + rowHeight), line);
      }
    }
    return top;
  }
}
