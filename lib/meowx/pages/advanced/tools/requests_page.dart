import 'dart:io';
import 'dart:typed_data';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/providers/providers.dart';
import 'ip_detail_dialog.dart' show showIpDetailDialog;
import '../../../theme/scroll_to_end.dart' show ScrollToEndBox;
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/format.dart';
import '../../../theme/m3.dart';
import '../../../theme/m3_kit.dart';
import '../../../theme/tokens.dart';
import '../../me/me_kit.dart';
import 'tools_kit.dart';

/// 请求记录（原 Bettbox 的 lib/views/connection/requests.dart + item.dart 按原功能重写成 M3 页）：
/// 内核报来的每条请求一行（分段清单、懒加载，新的在上），搜索、点代理链 / 进程图标加筛选关键词、自动滚到最新、清空，
/// 点一行看详情。读写的 provider 与原页一致（requestsProvider / requestsSearchProvider / requestsKeywordsProvider /
/// filteredRequestsProvider），打开时同样 watchRequests、关掉时 unwatchRequests。
class RequestsPage extends ConsumerStatefulWidget {
  const RequestsPage({super.key});

  @override
  ConsumerState<RequestsPage> createState() => _RequestsPageState();
}

class _RequestsPageState extends ConsumerState<RequestsPage> {
  late final ScrollController _scroll = ReverseScrollController();
  final _search = TextEditingController();
  bool _searchOpen = false;
  bool _autoScrollToEnd = false;
  List<String> _keywords = const [];

  @override
  void initState() {
    super.initState();
    // MeowX：request 消息平时只留原文不解码（见 ClashMessage.deferRequest），本页打开时补上并恢复逐条处理
    clashMessage.watchRequests();
    // 搜索框与关键词都从空开始，筛选条件跟着清掉（原页的关键词在首帧后同步成空；搜索词以前会残留上次的）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(requestsSearchProvider.notifier).state = '';
      ref.read(requestsKeywordsProvider.notifier).state = const [];
    });
  }

  @override
  void dispose() {
    clashMessage.unwatchRequests();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String value) => ref.read(requestsSearchProvider.notifier).state = value;

  void _setKeywords(List<String> keywords) {
    setState(() => _keywords = keywords);
    ref.read(requestsKeywordsProvider.notifier).state = keywords;
  }

  void _addKeyword(String keyword) {
    if (_keywords.contains(keyword)) return;
    _setKeywords([..._keywords, keyword]);
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (!_searchOpen) {
      _search.clear();
      _onSearch('');
    }
  }

  void _cancelAutoScroll() {
    if (_autoScrollToEnd) setState(() => _autoScrollToEnd = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final requests = ref.watch(filteredRequestsProvider);
    final filtering = _keywords.isNotEmpty || ref.watch(requestsSearchProvider).trim().isNotEmpty;
    final bottom = 16 + MediaQuery.paddingOf(context).bottom;

    final Widget list;
    if (requests.isEmpty) {
      list = ToolsEmptyState(
        icon: filtering ? Icons.search_off_rounded : Icons.inbox_rounded,
        text: filtering ? '没有匹配的请求' : '暂无请求',
      );
    } else {
      final count = requests.length;
      // 行高固定（随字号算出来，同原页的 itemExtentBuilder）：倒排列表一打开就要准确停在最上面那条，估算的高度会停偏
      final rowHeight = _RequestRow.heightFor(MediaQuery.textScalerOf(context));
      // 与原页一样倒排（新的在上，从顶端开始），条目少时贴顶
      list = ScrollToEndBox(
        controller: _scroll,
        dataSource: requests,
        enable: _autoScrollToEnd,
        reverse: true,
        onCancelToEnd: _cancelAutoScroll,
        child: Align(
          alignment: Alignment.topCenter,
          child: ListView.builder(
            reverse: true,
            shrinkWrap: count < 20,
            controller: _scroll,
            padding: EdgeInsets.only(top: 4, bottom: bottom),
            itemCount: count,
            itemExtentBuilder: (i, _) => rowHeight + (i == count - 1 ? 0 : 3),
            itemBuilder: (context, i) {
              final info = requests[i];
              // 倒排：数据的第 i 条画在从上往下第 count-1-i 行
              final row = count - 1 - i;
              return Padding(
                key: ValueKey(info.id),
                padding: EdgeInsets.only(top: row == 0 ? 0 : 3),
                child: M3SegmentSlot(
                  index: row,
                  count: count,
                  child: _RequestRow(info: info, height: rowHeight, onKeyword: _addKeyword),
                ),
              );
            },
          ),
        ),
      );
    }

    return MeSubPage(
      title: '请求记录',
      actions: [
        M3IconButton(
          icon: Icons.search_rounded,
          tooltip: _searchOpen ? '收起搜索' : '搜索',
          tonal: _searchOpen,
          onPressed: _toggleSearch,
        ),
        M3IconButton(
          icon: Icons.vertical_align_top_rounded,
          tooltip: '自动滚动',
          tonal: _autoScrollToEnd,
          onPressed: () => setState(() => _autoScrollToEnd = !_autoScrollToEnd),
        ),
        M3IconButton(
          icon: Icons.delete_sweep_outlined,
          tooltip: '清空',
          onPressed: () => ref.read(requestsProvider.notifier).clearRequests(),
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_searchOpen) ...[_SearchField(controller: _search, onChanged: _onSearch), const SizedBox(height: 10)],
            if (_keywords.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final k in _keywords)
                    InputChip(
                      label: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis),
                      labelStyle: TextStyle(fontSize: MeowFont.footnote, color: cs.onSecondaryContainer),
                      backgroundColor: cs.secondaryContainer,
                      side: BorderSide.none,
                      shape: const StadiumBorder(),
                      deleteIconColor: cs.onSecondaryContainer,
                      deleteButtonTooltipMessage: '去掉这个筛选',
                      onDeleted: () => _setKeywords([..._keywords]..remove(k)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Expanded(child: list),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(24)),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 22, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: MeowFont.subheadline, color: cs.onSurface),
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '搜索主机、IP、进程、代理',
                hintMaxLines: 1,
                hintStyle: TextStyle(fontSize: MeowFont.subheadline, color: cs.onSurfaceVariant),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: controller,
            builder: (_, _) => controller.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清除',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                    icon: Icon(Icons.close_rounded, size: 20, color: cs.onSurfaceVariant),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 一条请求：分段清单的一行。[进程图标] 协议://主机/IP:端口 + 时间 / 进程 · 上下行 / 代理链小胶囊（点了加筛选）；点行看详情。
class _RequestRow extends ConsumerWidget {
  const _RequestRow({required this.info, required this.height, required this.onKeyword});

  final TrackerInfo info;
  final double height;
  final ValueChanged<String> onKeyword;

  /// 每行文字都用固定行高（[_strut]），整行高度因此能直接算出来
  static const _lineHeight = 1.3;
  static StrutStyle _strut(double size) => StrutStyle(fontSize: size, height: _lineHeight, forceStrutHeight: true);
  static double _line(TextScaler s, double size) => s.scale(size) * _lineHeight;
  static double _chipHeight(TextScaler s) => _line(s, MeowFont.caption) + 8;

  /// 上下内边距 12 + 标题行 + 2 + 小字行 + 8 + 代理链那一行 + 1（取整余量）
  static double heightFor(TextScaler s) =>
      12 + _line(s, 15) + 2 + _line(s, MeowFont.caption) + 8 + _chipHeight(s) + 12 + 1;

  String get _sourceText {
    final progress = info.progressText.isNotEmpty ? '${info.progressText} · ' : '';
    final up = TrafficValue(value: info.upload).toString();
    final down = TrafficValue(value: info.download).toString();
    return '$progress$up↑ $down↓';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    // 原页同样只在 Android + 总是查找进程时画应用图标
    final showIcon = ref.watch(
      patchClashConfigProvider.select((s) => s.findProcessMode == FindProcessMode.always && system.isAndroid),
    );
    final pos = M3SegmentSlot.maybeOf(context);
    final radius = pos == null
        ? BorderRadius.circular(M3ListRow.outer)
        : MeowShape.segment(pos.index, pos.count, outer: M3ListRow.outer, inner: M3ListRow.inner);
    final small = TextStyle(
      fontSize: MeowFont.caption,
      color: cs.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final scaler = MediaQuery.textScalerOf(context);
    final smallStrut = _strut(MeowFont.caption);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                info.desc,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                strutStyle: _strut(15),
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onSurface),
              ),
            ),
            const SizedBox(width: 8),
            Text(fmtRelative(info.start), maxLines: 1, strutStyle: smallStrut, style: small),
          ],
        ),
        const SizedBox(height: 2),
        Text(_sourceText, maxLines: 1, overflow: TextOverflow.ellipsis, strutStyle: smallStrut, style: small),
        const SizedBox(height: 8),
        // 没有代理链也留着这一行的高度（行高固定）
        SizedBox(
          height: _chipHeight(scaler),
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            children: [
              for (final (i, chain) in info.chains.indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                _ChainChip(label: chain, strut: smallStrut, onTap: () => onKeyword(chain)),
              ],
            ],
          ),
        ),
      ],
    );
    return SizedBox(
      height: height,
      child: Material(
        color: cs.card,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _showRequestDetail(context, info),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showIcon) ...[
                  _ProcessIcon(process: info.metadata.process, onTap: onKeyword),
                  const SizedBox(width: 12),
                ],
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 代理链上的一个名字：小胶囊，点了把它加成筛选关键词。
class _ChainChip extends StatelessWidget {
  const _ChainChip({required this.label, required this.strut, required this.onTap});

  final String label;
  final StrutStyle strut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Material(
      color: cs.surfaceContainerHighest,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            label,
            maxLines: 1,
            strutStyle: strut,
            style: TextStyle(fontSize: MeowFont.caption, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

// ——— 进程图标（Android）：与原页同一套缓存，最多 50 个，最久没用的先丢 ———

final _iconCache = <String, Uint8List?>{};
final _iconCacheKeys = <String>[];
const _maxIconCacheSize = 50;
Uint8List? _defaultIconCache;
Future<Uint8List?>? _defaultIconFuture;

void _addToIconCache(String key, Uint8List? value) {
  if (_iconCache.containsKey(key)) {
    _iconCacheKeys.remove(key);
    _iconCacheKeys.add(key);
    _iconCache[key] = value;
    return;
  }
  while (_iconCacheKeys.length >= _maxIconCacheSize) {
    _iconCache.remove(_iconCacheKeys.removeAt(0));
  }
  _iconCacheKeys.add(key);
  _iconCache[key] = value;
}

Future<Uint8List?> _getPackageIcon(String process) async {
  if (process.isEmpty) return _getDefaultPackageIcon();
  final cached = _iconCache[process];
  if (cached != null) return cached;
  final icon = await app.getPackageIcon(process);
  if (icon != null) {
    _addToIconCache(process, icon);
    return icon;
  }
  return _getDefaultPackageIcon();
}

Future<Uint8List?> _getDefaultPackageIcon() {
  final cached = _defaultIconCache;
  if (cached != null) return Future.value(cached);
  return _defaultIconFuture ??= app.getPackageIcon('').then((icon) {
    if (icon != null) _defaultIconCache = icon;
    _defaultIconFuture = null;
    return icon;
  });
}

class _ProcessIcon extends StatefulWidget {
  const _ProcessIcon({required this.process, required this.onTap});

  final String process;
  final ValueChanged<String> onTap;

  @override
  State<_ProcessIcon> createState() => _ProcessIconState();
}

class _ProcessIconState extends State<_ProcessIcon> {
  late Future<Uint8List?> _icon = _getPackageIcon(widget.process);

  @override
  void didUpdateWidget(_ProcessIcon old) {
    super.didUpdateWidget(old);
    if (old.process != widget.process) _icon = _getPackageIcon(widget.process);
  }

  @override
  Widget build(BuildContext context) {
    const size = 40.0;
    final cacheSize = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    return GestureDetector(
      onTap: () {
        if (widget.process.isNotEmpty) widget.onTap(widget.process);
      },
      child: SizedBox.square(
        dimension: size,
        child: FutureBuilder<Uint8List?>(
          future: _icon,
          builder: (_, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) return const SizedBox.shrink();
            return Image(
              image: ResizeImage(MemoryImage(bytes), width: cacheSize, height: cacheSize, allowUpscaling: false),
              width: size,
              height: size,
              gaplessPlayback: true,
            );
          },
        ),
      ),
    );
  }
}

// ——— 详情（底部弹层） ———

Future<void> _showRequestDetail(BuildContext context, TrackerInfo info) {
  final cs = context.cs;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: cs.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
      child: SafeArea(
        top: false,
        child: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _RequestDetail(info: info),
          ),
        ),
      ),
    ),
  );
}

class _RequestDetail extends StatelessWidget {
  const _RequestDetail({required this.info});

  final TrackerInfo info;

  String get _ruleText => info.rulePayload.isNotEmpty ? '${info.rule}(${info.rulePayload})' : info.rule;

  static bool _isIp(String s) => InternetAddress.tryParse(s) != null;

  /// 「IP」「IP:端口」「[v6]:端口」拆成 (IP, 端口)；不是 IP 返回 null
  static (String, String?)? _parseIpAndPort(String text) {
    final raw = text.trim();
    if (raw.isEmpty) return null;
    if (raw.startsWith('[') && raw.contains(']')) {
      final end = raw.indexOf(']');
      final ip = raw.substring(1, end);
      final rest = raw.substring(end + 1);
      final port = rest.startsWith(':') ? rest.substring(1) : null;
      if (_isIp(ip)) return (ip, port);
    }
    if (raw.contains(':')) {
      final parts = raw.split(':');
      if (parts.length == 2 && int.tryParse(parts[1]) != null && _isIp(parts[0])) return (parts[0], parts[1]);
    }
    if (_isIp(raw)) return (raw, null);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final m = info.metadata;
    final remote = _parseIpAndPort(m.remoteDestination);
    final port = m.sourcePort.isNotEmpty ? m.sourcePort : null;
    final dPort = m.destinationPort.isNotEmpty ? m.destinationPort : null;
    final rows = <Widget>[
      _KvRow(label: '创建时间', value: info.start.showFull),
      if (info.progressText.isNotEmpty) _KvRow(label: '进程', value: info.progressText),
      _KvRow(label: '网络类型', value: m.network),
      _KvRow(label: '规则', value: _ruleText, mono: true),
      if (m.host.isNotEmpty)
        _isIp(m.host) ? _IpRow(label: '主机', ip: m.host) : _KvRow(label: '主机', value: m.host, mono: true),
      if (m.sourceIP.isNotEmpty) _IpRow(label: '来源', ip: m.sourceIP, port: port),
      if (m.destinationIP.isNotEmpty) _IpRow(label: '目标地址', ip: m.destinationIP, port: dPort),
      // 上下行跟着连接列表实时刷新；连接还在时多一行实时速度
      ..._liveTraffic(),
      if (m.destinationGeoIP.isNotEmpty) _KvRow(label: '目标地理定位', value: m.destinationGeoIP.join(' ')),
      if (m.destinationIPASN.isNotEmpty) _KvRow(label: '目标 IP ASN', value: m.destinationIPASN),
      if (m.dnsMode != null) _KvRow(label: 'DNS 模式', value: m.dnsMode!.name),
      if (m.specialProxy.isNotEmpty) _KvRow(label: '特殊代理', value: m.specialProxy),
      if (m.specialRules.isNotEmpty) _KvRow(label: '特殊规则', value: m.specialRules),
      if (m.remoteDestination.isNotEmpty)
        remote != null
            ? _IpRow(label: '远程目标', ip: remote.$1, port: remote.$2)
            : _KvRow(label: '远程目标', value: m.remoteDestination, mono: true),
      _ChainsRow(chains: info.chains),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
          child: Text(
            info.desc,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: context.cs.onSurface),
          ),
        ),
        MeSection(title: '详情', children: rows),
      ],
    );
  }

  List<Widget> _liveTraffic() => [
    Consumer(
      builder: (context, ref, _) {
        final live = ref.watch(connectionsProvider.select((list) => list.firstWhereOrNull((e) => e.id == info.id)));
        final upload = live?.upload ?? info.upload;
        final download = live?.download ?? info.download;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: meDivided(context, [
            _KvRow(
              label: '上传',
              value: TrafficValue(value: upload).show,
            ),
            _KvRow(
              label: '下载',
              value: TrafficValue(value: download).show,
            ),
            if (live != null)
              _KvRow(
                label: '实时速度',
                value: Traffic(up: live.uploadSpeed, down: live.downloadSpeed).toString(),
              ),
          ]),
        );
      },
    ),
  ];
}

/// 详情的一行：左键右值，值右对齐、可换行。
class _KvRow extends StatelessWidget {
  const _KvRow({required this.label, required this.value, this.mono = false});

  final String label, value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: mono
                  ? MeowFont.mono(size: MeowFont.footnote, color: cs.onSurface)
                  : TextStyle(fontSize: MeowFont.footnote, color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情里的 IP 行：IP 是一颗主色小胶囊（图标按 TUN / 局域网 / 公网分），点了查这个 IP 的归属；有端口时后面跟「:端口」。
class _IpRow extends StatelessWidget {
  const _IpRow({required this.label, required this.ip, this.port});

  final String label, ip;
  final String? port;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final icon = switch (utils.classifyIp(ip)) {
      IpCategory.tun => Icons.stacked_line_chart_rounded,
      IpCategory.lan => Icons.shuffle_rounded,
      IpCategory.public => Icons.search_rounded,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(
                  child: Material(
                    color: cs.primaryContainer,
                    shape: const StadiumBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => showIpDetailDialog(context, ip),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 14, color: cs.onPrimaryContainer),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                ip,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: MeowFont.mono(
                                  size: MeowFont.footnote,
                                  weight: FontWeight.w700,
                                  color: cs.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (port != null && port!.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(
                    ':$port',
                    style: MeowFont.mono(size: MeowFont.footnote, color: cs.onSurface),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情最后一行：代理链，每一跳一颗小胶囊。
class _ChainsRow extends StatelessWidget {
  const _ChainsRow({required this.chains});

  final List<String> chains;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '代理链',
            style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: [for (final c in chains) M3Badge(c)],
            ),
          ),
        ],
      ),
    );
  }
}
