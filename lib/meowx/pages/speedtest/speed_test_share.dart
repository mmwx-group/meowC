import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../../state/speed_board.dart';
import '../../state/speed_test.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart' show BrandHead, meowRounded;
import 'speed_test_history_page.dart' show SpeedTestRecordChartPainter;

/// 测速记录的分享图（工单 #1270，与 iOS / macOS 同一份需求）：1920 × 1080 像素的 16:9 横图（2026-10-29 用户从六版里选的
/// 「宽版三栏（D）」，设计稿 `Design/ui-redesign/speedtest-share-options.html` 的 `.sc.d`；以前是 1080 × 1350 的竖图），
/// 从记录详情页 / 测速页页头生成 PNG：安卓「分享」经 share_plus 弹系统分享面板（同 iOS），Windows「保存分享图」经
/// `picker.saveFile` 另存新档。
///
/// 配色跟着分享时 App 实际生效的外观（主题色 + 深浅，同 iOS / macOS），但**磨砂强度固定按缺省 0.5**（[tokensFor]）：
/// 液态玻璃浅色下卡片与页面底本来就只差一点，磨砂调到 0 时按当前那份画，卡片在图上完全看不出来。
/// 页面底：经典 = 平涂 [MeowTokens.bg]；液态玻璃 = 底色渐层（[MeowTokens.bgGradient]，方向照 [MeowTokens.bgDiagonal]），
/// 不画光斑与插画（自选的照片不能跟着分享出去）。卡片是不透明的 [MeowTokens.elevSolid]（经典 = 卡片色；液态玻璃 = 玻璃卡片叠在
/// 页面底上的实色），不画玻璃效果。字、强调色、下载紫、分隔线都取同一份 token；页头 App 图标按深浅取浅 / 深两张（同 [BrandHead]）。
///
/// 版式（自上而下）：页头一行（App 图标 + MeowX + 网络测速，右边日期时间）→ 中间三栏（列宽 1.3 : 0.9 : 1.15，占剩下全部高度）：
/// 下载大卡（标签、大数字 + Mbps、峰值，内容垂直居中；四位数放不下先缩数字、不截断）、上传 / 延迟上下两格（只测下载的源上传
/// 画「—」+「此测速源只测下载」）、参数表（测速源 · 线程、网络、协议——后两样记了才有——出站、出口，行均匀分布填满高度，
/// 最后一行允许折成两行）→ 底部速率曲线卡（标题 + 右边图例，曲线横贯整宽，同详情页的画法）。出口只写 ASN / 运营商，
/// **不写 IP**（直连测速时那是用户自家的公网 IP）。不画任何可点的控件样式。
/// 已上传到测速榜（speed_board.dart）时照设计稿 D 多两样：下载卡底部「超越了 x% 的测速」+ 比较范围 + 进度条（服务端给了百分位
/// 才画，样本不够时没有），页头右边日期下面一行结果链接（「speed.meowx.net/r/7Kq2Xp」）。没上传的图与以前一样。
///
/// 按 800 × 450 的逻辑尺寸排（1cqw = 卡片宽度的 1% = 8 逻辑像素，字号、间距都照设计稿的 cqw 换算）、整张放大 2.4 倍。
class SpeedTestShareImage {
  SpeedTestShareImage._();

  static const width = 1920;
  static const height = 1080;
  static const _scale = width / 800;

  /// 页头的 App 图标：浅色白发、深色黑发（同 [BrandHead]）
  static String iconAsset(Brightness brightness) =>
      brightness == Brightness.dark ? 'assets/images/icon_256.png' : 'assets/images/icon_light_256.png';

  /// 分享图用的配色：App 当前的外观（[look]，「我的 › 外观」）在实际深浅色下解析，只把磨砂强度换成缺省 0.5。
  /// 经典主题不受磨砂影响，就是 App 当前那一份。
  static MeowTokens tokensFor(Brightness brightness, MeowLook look) =>
      MeowTokens.resolve(brightness, look.withGlassFrost(0.5));

  /// 失败的记录不给分享
  static bool canShare(SpeedTestRecord record) => !record.failed;

  /// 「MeowX-speedtest-20261029-1432.png」
  static String fileName(SpeedTestRecord record) {
    String two(int v) => v.toString().padLeft(2, '0');
    final d = record.date;
    return 'MeowX-speedtest-${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}.png';
  }

  /// 生成 PNG；失败的记录返回 null。[look] / [brightness] = App 当前的外观与实际深浅（配色按 [tokensFor] 推）；
  /// [textStyle] 是 App 正文的字族（含回落字族），图里的字都用它；[icon] 缺省按深浅读 [iconAsset]。
  static Future<Uint8List?> render(
    SpeedTestRecord record, {
    required MeowLook look,
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
      _SharePainter(record, content, tokensFor(brightness, look), textStyle ?? const TextStyle(), logo).paint(canvas);
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
    this.network,
    this.protocol,
    required this.outbound,
    this.exit,
    this.percentile,
    this.link,
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

  /// 本机网络「Wi-Fi」「5G」…；旧记录与没取到的 null
  final String? network;

  /// 节点协议「VLESS」「Shadowsocks」…（只到顶层）；直连、旧记录与查不到的 null
  final String? protocol;

  /// 节点名；直连「直连 · 本机网络」
  final String outbound;

  /// 出口「AS2516 KDDI」（只有 ASN / 运营商，不带 IP）；查不到 null
  final String? exit;

  /// 测速榜的超越比例（已上传且服务端给了才有）
  final SpeedBoardPercentile? percentile;

  /// 测速榜结果链接，去掉协议头（「speed.meowx.net/r/7Kq2Xp」）；没上传 null
  final String? link;

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 失败的记录返回 null
  static SpeedTestShareContent? of(SpeedTestRecord r) {
    if (r.failed) return null;
    final d = r.date;
    final hasUpload = r.source.hasUpload;
    final e = r.exit;
    final exit = e == null ? '' : [?e.asnTag, ?e.shortOrg].join(' ');
    final board = r.board?.isUploaded == true ? r.board : null;
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
      network: r.network,
      protocol: r.isDirect ? null : r.protocol,
      outbound: r.isDirect ? '直连 · 本机网络' : r.outbound,
      exit: exit.isEmpty ? null : exit,
      percentile: board?.percentile,
      link: board?.shortUrl,
    );
  }
}

/// 分享图的版式（逻辑坐标，800 × 450，1cqw = 8；单测按它算取点位置）。
abstract final class SpeedTestShareLayout {
  static const w = 800.0, h = 450.0;

  /// 1cqw：设计稿里所有尺寸的单位（卡片宽度的 1%）
  static const cqw = 8.0;

  /// 页面四边留白、块之间的间距、卡片圆角
  static const padH = 4.2 * cqw, padV = 3.6 * cqw, gap = 2 * cqw, radius = 2.6 * cqw;

  /// 卡片内边距（上下 / 左右）
  static const cardPadV = 2.2 * cqw, cardPadH = 2.6 * cqw;

  /// 页头（App 图标那一行）的高度；底部速率曲线卡的高度
  static const headerHeight = 4.4 * cqw, chartHeight = 10.5 * cqw;

  /// 三栏的列宽比
  static const columnWeights = [1.3, 0.9, 1.15];

  static const inner = w - padH * 2;

  /// 中间三栏那一块（页头与曲线卡之间）
  static const mainTop = padV + headerHeight + gap;
  static const mainBottom = h - padV - chartHeight - gap;

  /// 底部速率曲线卡
  static const chart = Rect.fromLTWH(padH, h - padV - chartHeight, inner, chartHeight);

  /// 三栏各自的框（下载 / 上传 · 延迟 / 参数）
  static List<Rect> get columns {
    final total = columnWeights.fold(0.0, (a, b) => a + b);
    final avail = inner - gap * (columnWeights.length - 1);
    final out = <Rect>[];
    var x = padH;
    for (final weight in columnWeights) {
      final width = avail * weight / total;
      out.add(Rect.fromLTWH(x, mainTop, width, mainBottom - mainTop));
      x += width + gap;
    }
    return out;
  }
}

/// 在 1920 × 1080 的画布上画（坐标按 [SpeedTestShareLayout] 的 800 × 450 版式，画之前整体放大 [SpeedTestShareImage._scale]）。
class _SharePainter {
  _SharePainter(this.record, this.content, this.mm, this.base, this.icon);
  final SpeedTestRecord record;
  final SpeedTestShareContent content;
  final MeowTokens mm;
  final TextStyle base;
  final ui.Image? icon;

  static const w = SpeedTestShareLayout.w, h = SpeedTestShareLayout.h, cqw = SpeedTestShareLayout.cqw;
  static const padH = SpeedTestShareLayout.padH, padV = SpeedTestShareLayout.padV;
  static const radius = SpeedTestShareLayout.radius;
  static const cardPadV = SpeedTestShareLayout.cardPadV, cardPadH = SpeedTestShareLayout.cardPadH;

  final _painters = <TextPainter>[];

  TextStyle _style(double size, Color color, {FontWeight weight = FontWeight.w400, bool rounded = false}) => base.copyWith(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: 1.3,
    fontFamilyFallback: rounded ? meowRounded : null,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// 大数字：圆体、最粗、等宽数字、行高收紧（设计稿 `.num`）
  TextStyle _num(double size, Color color) =>
      _style(size, color, weight: FontWeight.w900, rounded: true).copyWith(height: 1.05);

  TextPainter _text(String text, TextStyle style, {double maxWidth = double.infinity, int maxLines = 1}) {
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    _painters.add(p);
    return p;
  }

  double _baseline(TextPainter p) => p.computeDistanceToActualBaseline(TextBaseline.alphabetic);

  /// 卡片：不透明的实色（液态玻璃下 [MeowTokens.elev] 是半透明的，用叠好的 [MeowTokens.elevSolid]）
  void _card(Canvas canvas, Rect rect) =>
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(radius)), Paint()..color = mm.elevSolid);

  /// 页面底：平涂 [MeowTokens.bg]；液态玻璃是底色渐层，按整张图铺（斜向 = 左上 → 右下，否则自上而下，同 App 里按整屏铺）
  Paint _page() {
    final g = mm.bgGradient;
    if (g == null) return Paint()..color = mm.bg;
    return Paint()..shader = ui.Gradient.linear(Offset.zero, mm.bgDiagonal ? const Offset(w, h) : const Offset(0, h), g);
  }

  Paint get _line => Paint()
    ..color = mm.line
    ..strokeWidth = 1;

  /// 「● 标签」（圆点 .9em、与字隔 .4em，同设计稿 `.dot`）；[dot] 为 null 不画圆点。返回占的高度
  double _label(Canvas canvas, Offset at, String title, Color? dot) {
    const size = 2 * cqw;
    final label = _text(title, _style(size, mm.t2, weight: FontWeight.w700));
    var x = at.dx;
    if (dot != null) {
      const d = size * 0.9;
      canvas.drawCircle(Offset(x + d / 2, at.dy + label.height / 2), d / 2, Paint()..color = dot);
      x += d + size * 0.4;
    }
    label.paint(canvas, Offset(x, at.dy));
    return label.height;
  }

  /// 数字 + 单位（单位按基线紧跟数字，隔 [unitGap]）；[number] / [unit] 已排好
  void _paintValue(Canvas canvas, Offset at, TextPainter number, TextPainter? unit, double unitGap) {
    number.paint(canvas, at);
    if (unit != null) {
      unit.paint(canvas, Offset(at.dx + number.width + unitGap, at.dy + _baseline(number) - _baseline(unit)));
    }
  }

  /// 排一个数字 + 单位：数字从 [size] 起，加上单位放不进 [maxWidth] 就把数字缩小到放得下（单位不缩、不截断）
  (TextPainter, TextPainter) _fitValue(String value, Color color, double size, String unit, double unitSize, double unitGap,
      double maxWidth) {
    final u = _text(unit, _style(unitSize, mm.t2, weight: FontWeight.w700));
    final room = maxWidth - unitGap - u.width;
    var s = size;
    var n = _text(value, _num(s, color));
    if (n.width > room && n.width > 0) {
      s = (size * room / n.width).floorToDouble();
      n = _text(value, _num(s, color));
      while (n.width > room && s > 8) {
        s -= 1;
        n = _text(value, _num(s, color));
      }
    }
    return (n, u);
  }

  void paint(Canvas canvas) {
    canvas
      ..save()
      ..scale(SpeedTestShareImage._scale)
      ..drawRect(const Rect.fromLTWH(0, 0, w, h), _page());
    try {
      _header(canvas, padV);
      final [download, two, params] = SpeedTestShareLayout.columns;
      _downloadCard(canvas, download);
      _uploadLatencyCard(canvas, two);
      _paramsCard(canvas, params);
      _chartCard(canvas, SpeedTestShareLayout.chart);
    } finally {
      canvas.restore();
      for (final p in _painters) {
        p.dispose();
      }
    }
  }

  /// 页头：圆角 App 图标 + 「MeowX」「网络测速」（同一基线），右边日期时间；都按图标的中线对齐
  void _header(Canvas canvas, double top) {
    const size = SpeedTestShareLayout.headerHeight;
    final img = icon;
    final iconRect = Rect.fromLTWH(padH, top, size, size);
    if (img != null) {
      canvas
        ..save()
        ..clipRRect(RRect.fromRectAndRadius(iconRect, const Radius.circular(size * 0.3)))
        ..drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          iconRect,
          Paint()..filterQuality = FilterQuality.high,
        )
        ..restore();
    }
    final centerY = top + size / 2;
    // 右边：日期；上传过的下面再一行结果链接（等宽字），两行一起按图标的中线居中、右对齐（设计稿 `.meta`）
    final metaStyle = content.link == null ? _style(1.9 * cqw, mm.t2) : _style(1.9 * cqw, mm.t2).copyWith(height: 1.35);
    final date = _text(content.dateTime, metaStyle);
    final link = content.link == null
        ? null
        : _text(content.link!, metaStyle.copyWith(fontFamily: MeowFont.monoFamily, fontFamilyFallback: MeowFont.monoFallback),
            maxWidth: w / 2);
    final metaHeight = date.height + (link?.height ?? 0);
    final metaTop = centerY - metaHeight / 2;
    date.paint(canvas, Offset(w - padH - date.width, metaTop));
    link?.paint(canvas, Offset(w - padH - link.width, metaTop + date.height));
    final metaWidth = link == null || date.width > link.width ? date.width : link.width;
    final x = padH + size + 1.6 * cqw;
    final brand = _text('MeowX', _style(3.2 * cqw, mm.t1, weight: FontWeight.w900, rounded: true));
    final brandTop = centerY - brand.height / 2;
    brand.paint(canvas, Offset(x, brandTop));
    final subLeft = x + brand.width + 1.2 * cqw;
    final sub = _text('网络测速', _style(2 * cqw, mm.t2, weight: FontWeight.w600), maxWidth: w - padH - metaWidth - 2 * cqw - subLeft);
    sub.paint(canvas, Offset(subLeft, brandTop + _baseline(brand) - _baseline(sub)));
  }

  /// 下载大卡：「● 下载」、大数字 + Mbps、峰值；有超越比例时卡片底部是「超越了 x% 的测速」+ 比较范围 + 进度条（设计稿 `.beat`），
  /// 上面三样在剩下的高度里垂直居中；没有就整卡居中
  void _downloadCard(Canvas canvas, Rect r) {
    _card(canvas, r);
    final left = r.left + cardPadH, maxWidth = r.width - cardPadH * 2;
    final beatTop = _beat(canvas, r, left, maxWidth);
    final labelHeight = _text(' ', _style(2 * cqw, mm.t2, weight: FontWeight.w700)).height;
    final peak = content.downloadPeak == null ? null : _text(content.downloadPeak!, _style(2 * cqw, mm.t2), maxWidth: maxWidth);
    final fixed = labelHeight + 0.6 * cqw + (peak == null ? 0 : 0.6 * cqw + peak.height);
    var (number, unit) = _fitValue(content.download, mm.down, 12 * cqw, 'Mbps', 2.8 * cqw, 0.8 * cqw, maxWidth);
    double y;
    if (beatTop == null) {
      y = r.top + (r.height - fixed - number.height) / 2;
    } else {
      // 上面三样排在卡片顶边到超越比例之间：放不下就把数字再缩小（不截断、不压到下面那块）
      final top = r.top + cardPadV, avail = beatTop - 1.2 * cqw - top;
      if (fixed + number.height > avail && number.height > 0) {
        final size = (12 * cqw * (avail - fixed) / number.height).floorToDouble().clamp(8.0, 12 * cqw);
        (number, unit) = _fitValue(content.download, mm.down, size, 'Mbps', 2.8 * cqw, 0.8 * cqw, maxWidth);
      }
      final spare = avail - fixed - number.height;
      y = top + (spare > 0 ? spare / 2 : 0);
    }
    y += _label(canvas, Offset(left, y), '下载', mm.down) + 0.6 * cqw;
    _paintValue(canvas, Offset(left, y), number, unit, 0.8 * cqw);
    y += number.height;
    if (peak != null) peak.paint(canvas, Offset(left, y + 0.6 * cqw));
  }

  /// 下载卡底部的超越比例（玫红）：「超越了 **82%** 的测速」、下一行比较范围、再下面一条进度条；从卡片底边往上排。
  /// 返回这一块的顶边；没有超越比例返回 null、不画
  double? _beat(Canvas canvas, Rect r, double left, double maxWidth) {
    final p = content.percentile;
    if (p == null) return null;
    final rose = mm.accent;
    final small = _style(2.1 * cqw, rose, weight: FontWeight.w700);
    final big = _num(3 * cqw, rose);
    final title = TextPainter(
      text: TextSpan(children: [
        TextSpan(text: '超越了 ', style: small),
        TextSpan(text: '${p.value}%', style: big),
        TextSpan(text: ' 的测速', style: small),
      ]),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    _painters.add(title);
    final scope = p.scope.isEmpty ? null : _text(p.scope, _style(1.8 * cqw, mm.t2, weight: FontWeight.w500), maxWidth: maxWidth);
    const barHeight = 0.9 * cqw, barGap = 0.8 * cqw, scopeGap = 0.2 * cqw;
    final barTop = r.bottom - cardPadV - barHeight;
    final scopeTop = scope == null ? barTop - barGap : barTop - barGap - scope.height;
    final titleTop = scopeTop - (scope == null ? 0 : scopeGap) - title.height;
    title.paint(canvas, Offset(left, titleTop));
    scope?.paint(canvas, Offset(left, scopeTop));
    const radius = Radius.circular(0.5 * cqw);
    final track = Rect.fromLTWH(left, barTop, maxWidth, barHeight);
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(track, radius))
      ..drawRect(track, Paint()..color = rose.withValues(alpha: 0.15))
      ..drawRect(Rect.fromLTWH(left, barTop, maxWidth * p.value.clamp(0, 100) / 100, barHeight), Paint()..color = rose)
      ..restore();
    return titleTop;
  }

  /// 上传 / 延迟卡：上下两格各占一半（格间 1.6cqw），下面那格顶上一条细线、再空 1.6cqw；
  /// 每格「标签」+ 数字 + 单位；没有值（只测下载的源的上传、没测到的延迟）画次级色的「—」，上传再加一行小字说明
  void _uploadLatencyCard(Canvas canvas, Rect r) {
    _card(canvas, r);
    final left = r.left + cardPadH, right = r.right - cardPadH, maxWidth = right - left;
    final top = r.top + cardPadV, bottom = r.bottom - cardPadV;
    const rowGap = 1.6 * cqw;
    final cell = (bottom - top - rowGap) / 2;

    void metric(double y, String title, Color? dot, String? value, Color tint, String unit, String? note) {
      y += _label(canvas, Offset(left, y), title, dot) + 0.5 * cqw;
      if (value == null) {
        final dash = _text('—', _num(6 * cqw, mm.t2));
        dash.paint(canvas, Offset(left, y));
        y += dash.height;
      } else {
        final (number, u) = _fitValue(value, tint, 6 * cqw, unit, 1.8 * cqw, 0.5 * cqw, maxWidth);
        _paintValue(canvas, Offset(left, y), number, u, 0.5 * cqw);
        y += number.height;
      }
      if (note != null) _text(note, _style(1.6 * cqw, mm.t2), maxWidth: maxWidth).paint(canvas, Offset(left, y + 0.3 * cqw));
    }

    metric(top, '上传', mm.accent, content.upload, mm.accent, 'Mbps', content.upload == null ? content.uploadNote : null);
    final lineY = top + cell + rowGap;
    canvas.drawLine(Offset(left, lineY), Offset(right, lineY), _line);
    metric(lineY + 1.6 * cqw, '延迟', null, content.latency, mm.t1, 'ms', null);
  }

  /// 参数卡：「键 … 值」按行、行间细线、行均匀分布填满高度；值右对齐、加粗，放不下截尾；
  /// 最后一行（通常是出口）允许折成两行，连两行都放不下（行太多）再退回一行截尾
  void _paramsCard(Canvas canvas, Rect r) {
    _card(canvas, r);
    final rows = [
      ('测速源', content.sourceLine),
      if (content.network != null) ('网络', content.network!),
      if (content.protocol != null) ('协议', content.protocol!),
      ('出站', content.outbound),
      if (content.exit != null) ('出口', content.exit!),
    ];
    final left = r.left + cardPadH, right = r.right - cardPadH;
    final top = r.top + cardPadV, bottom = r.bottom - cardPadV;
    const rowPad = 0.4 * cqw, keyGap = 1.5 * cqw;
    final keyStyle = _style(1.9 * cqw, mm.t2);
    final valueStyle = _style(2.1 * cqw, mm.t1, weight: FontWeight.w600);
    final keys = [for (final (k, _) in rows) _text(k, keyStyle)];
    List<TextPainter> layoutValues(int lastLines) => [
      for (final (i, (_, v)) in rows.indexed)
        _text(
          v,
          i == rows.length - 1 ? valueStyle.copyWith(height: 1.25) : valueStyle,
          maxWidth: right - left - keys[i].width - keyGap,
          maxLines: i == rows.length - 1 ? lastLines : 1,
        ),
    ];
    var values = layoutValues(2);
    List<double> heights() => [
      for (var i = 0; i < rows.length; i++) (keys[i].height > values[i].height ? keys[i].height : values[i].height) + rowPad * 2,
    ];
    var rowHeights = heights();
    var extra = (bottom - top - rowHeights.fold(0.0, (a, b) => a + b)) / rows.length;
    if (extra < 0) {
      values = layoutValues(1);
      rowHeights = heights();
      extra = ((bottom - top - rowHeights.fold(0.0, (a, b) => a + b)) / rows.length).clamp(0, double.infinity);
    }
    var y = top;
    for (var i = 0; i < rows.length; i++) {
      final rowHeight = rowHeights[i] + extra;
      final k = keys[i], v = values[i];
      // 值靠行的中线放，键与值的第一行同一基线
      final valueTop = y + (rowHeight - v.height) / 2;
      v.paint(canvas, Offset(right - v.width, valueTop));
      k.paint(canvas, Offset(left, valueTop + _baseline(v) - _baseline(k)));
      y += rowHeight;
      if (i < rows.length - 1) canvas.drawLine(Offset(left, y), Offset(right, y), _line);
    }
  }

  /// 速率曲线卡（下载 + 上传两条，同详情页的画法）：标题行右边是图例，曲线横贯卡片内宽
  void _chartCard(Canvas canvas, Rect rect) {
    const padTop = 1.6 * cqw, padSide = 2.6 * cqw, padBottom = 1.8 * cqw;
    _card(canvas, rect);
    final style = _style(1.9 * cqw, mm.t2, weight: FontWeight.w700);
    final title = _text('速率曲线', style);
    title.paint(canvas, Offset(rect.left + padSide, rect.top + padTop));
    // 图例从右往左排：只测下载的没有上传那条
    final legends = [('下载', mm.down), if (record.uploadSamples.length > 1) ('上传', mm.accent)];
    final centerY = rect.top + padTop + title.height / 2;
    const dot = 1.9 * cqw * 0.9;
    var right = rect.right - padSide;
    for (final (label, color) in legends.reversed) {
      final t = _text(label, style);
      final textLeft = right - t.width;
      t.paint(canvas, Offset(textLeft, centerY - t.height / 2));
      final dotLeft = textLeft - 1.9 * cqw * 0.4 - dot;
      canvas.drawCircle(Offset(dotLeft + dot / 2, centerY), dot / 2, Paint()..color = color);
      right = dotLeft - 1.9 * cqw * 0.8;
    }
    final chart = Rect.fromLTRB(
      rect.left + padSide,
      rect.top + padTop + title.height + 0.6 * cqw,
      rect.right - padSide,
      rect.bottom - padBottom,
    );
    if (chart.height <= 10) return;
    canvas
      ..save()
      ..translate(chart.left, chart.top);
    SpeedTestRecordChartPainter(record.downloadSamples, record.uploadSamples, mm.down, mm.accent, mm.line)
        .paint(canvas, chart.size);
    canvas.restore();
  }
}
