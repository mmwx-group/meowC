import 'dart:io';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/config.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' hide context;

import '../../../state/format.dart';
import '../../../theme/m3.dart';
import '../../../theme/m3_kit.dart';
import '../../../theme/tokens.dart';
import '../../me/me_kit.dart';
import 'tools_kit.dart';

/// 资源（原 Bettbox 的 lib/views/resources.dart 按原功能重写成 M3 页）：GeoSite / MMDB / ASN 三份数据文件的
/// 大小与更新时间、下载地址（可改、可恢复缺省）、单个同步与全部同步，右上角重置全部地址；内置的 BundleMRS 只显示。
/// 读写的 provider 与调用的核心 / controller 方法和原页一致，只换界面。

/// 正在同步的数据文件（[ToolsGeoItem.key]）
final toolsGeoUpdatingKeysProvider = StateProvider.autoDispose<Set<String>>((ref) => {});

@immutable
class ToolsGeoItem {
  const ToolsGeoItem({required this.label, required this.key, required this.fileName});

  final String label;
  final String key;
  final String fileName;
}

/// BundleMRS 是随 App 内置的规则包，只显示大小与来源，不能改地址、不能同步
const _bundleMRSUrl = 'https://github.com/appshubcc/bett-rules/releases/download/latest/BundleMRS.7z';

class ResourcesPage extends ConsumerWidget {
  const ResourcesPage({super.key});

  static const geoItems = <ToolsGeoItem>[
    ToolsGeoItem(label: 'GeoSite', fileName: geoSiteFileName, key: 'geosite'),
    ToolsGeoItem(label: 'MMDB', fileName: mmdbFileName, key: 'mmdb'),
    ToolsGeoItem(label: 'ASN', fileName: asnFileName, key: 'asn'),
    ToolsGeoItem(label: 'MRS', fileName: bundleMRSFileName, key: 'mrs'),
  ];

  Future<void> _syncAll(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(toolsGeoUpdatingKeysProvider.notifier);
    if (notifier.state.isNotEmpty) return;

    final items = geoItems.where((g) => g.key != 'mrs').toList();
    notifier.state = items.map((e) => e.key).toSet();

    final errors = <String>[];
    try {
      await Future.wait(
        items.map((g) async {
          try {
            final message = await clashCore.updateGeoData(UpdateGeoDataParams(geoName: g.fileName, geoType: g.label));
            if (message.isNotEmpty) errors.add('${g.label}: $message');
          } catch (e) {
            errors.add('${g.label}: $e');
          } finally {
            notifier.update((s) => Set.of(s)..remove(g.key));
          }
        }),
      );
      if (errors.isNotEmpty && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            scrollable: true,
            title: const Text('同步失败'),
            content: Text(errors.join('\n')),
            actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('好'))],
          ),
        );
      }
    } finally {
      notifier.state = {};
    }
  }

  Future<void> _resetAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置下载地址'),
        content: const Text('GeoSite / MMDB / ASN 的下载地址全部恢复成缺省地址。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('重置')),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(patchClashConfigProvider.notifier).updateState((state) => state.copyWith(geoXUrl: defaultGeoXUrl));
    await globalState.appController.setupClashConfig();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updating = ref.watch(toolsGeoUpdatingKeysProvider.select((keys) => keys.isNotEmpty));
    return MeSubPage.list(
      title: '资源',
      actions: [
        M3IconButton(icon: Icons.replay_rounded, tooltip: '重置', onPressed: () => _resetAll(context, ref)),
        ToolsBusyIconButton(
          icon: Icons.sync_rounded,
          tooltip: '全部同步',
          busy: updating,
          tonal: true,
          onPressed: () => _syncAll(context, ref),
        ),
      ],
      children: [
        MeSection(
          children: [for (final g in geoItems) _GeoRow(key: ValueKey(g.key), item: g)],
        ),
        const MeCaption('GeoSite、MMDB、ASN 是规则匹配用的数据文件，可以改下载地址；MRS 规则包随 App 内置，不在这里更新。'),
      ],
    );
  }
}

class _GeoRow extends ConsumerStatefulWidget {
  const _GeoRow({super.key, required this.item});

  final ToolsGeoItem item;

  @override
  ConsumerState<_GeoRow> createState() => _GeoRowState();
}

class _GeoRowState extends ConsumerState<_GeoRow> {
  ToolsGeoItem get item => widget.item;

  /// 文件大小与更新时间：进页面读一次，同步完再读一次（不在每次重建时重读）
  late Future<FileInfo> _info = _fileInfo(item.fileName);

  Future<void> _editUrl(String url) async {
    final newUrl = await showDialog<String>(
      context: context,
      builder: (_) => _GeoUrlDialog(title: item.label, url: url, defaultValue: defaultGeoXUrl.toJson()[item.key]),
    );
    if (newUrl == null || newUrl == url || !mounted) return;
    try {
      if (!newUrl.isHttpUrl) throw 'Invalid url';
      ref.read(patchClashConfigProvider.notifier).updateState((state) {
        final map = state.geoXUrl.toJson();
        map[item.key] = newUrl;
        return state.copyWith(geoXUrl: GeoXUrl.fromJson(map));
      });
      await globalState.appController.setupClashConfig();
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(item.label),
          content: Text(e == 'Invalid url' ? '不是有效的 http(s) 地址' : e.toString()),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('好'))],
        ),
      );
    }
  }

  Future<FileInfo> _fileInfo(String fileName) async {
    final homePath = await appPath.homeDirPath;
    final file = File(join(homePath, fileName));
    final lastModified = await file.lastModified();
    final size = await file.length();
    return FileInfo(size: size, lastModified: lastModified);
  }

  Future<void> _sync() async {
    final notifier = ref.read(toolsGeoUpdatingKeysProvider.notifier);
    if (ref.read(toolsGeoUpdatingKeysProvider).contains(item.key)) return;

    await globalState.appController.safeRun<void>(
      () async {
        notifier.update((s) => Set.of(s)..add(item.key));
        try {
          final message = await clashCore.updateGeoData(
            UpdateGeoDataParams(geoName: item.fileName, geoType: item.label),
          );
          if (message.isNotEmpty) throw message;
        } finally {
          notifier.update((s) => Set.of(s)..remove(item.key));
        }
      },
      silence: false,
      needLoading: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    // 同步完重读一次文件大小与时间
    ref.listen(toolsGeoUpdatingKeysProvider.select((s) => s.contains(item.key)), (prev, next) {
      if (prev == true && next == false && mounted) setState(() => _info = _fileInfo(item.fileName));
    });
    final url = ref.watch(patchClashConfigProvider.select((state) => state.geoXUrl.toJson()[item.key]));
    final syncing = ref.watch(toolsGeoUpdatingKeysProvider.select((s) => s.contains(item.key)));
    final bundled = item.key == 'mrs';
    final hasDetail = url != null || bundled;

    final title = Text(
      item.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: MeowFont.body, fontWeight: FontWeight.w700, color: cs.onSurface),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, bundled ? 16 : 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: title),
              if (bundled) const M3Badge('内置'),
              if (!bundled && url != null) ...[
                M3IconButton(
                  icon: Icons.edit_outlined,
                  tooltip: '修改下载地址',
                  size: 40,
                  onPressed: syncing ? null : () => _editUrl(url),
                ),
                const SizedBox(width: 8),
                ToolsBusyIconButton(icon: Icons.sync_rounded, tooltip: '同步', size: 40, busy: syncing, onPressed: _sync),
              ],
            ],
          ),
          if (hasDetail) ...[
            const SizedBox(height: 4),
            FutureBuilder<FileInfo>(
              future: _info,
              builder: (_, snapshot) {
                final info = snapshot.data;
                final text = info == null
                    ? (snapshot.hasError ? '本机还没有这个文件' : '读取中…')
                    : bundled
                    ? '${TrafficValue(value: info.size).show}  ·  内置'
                    : '${TrafficValue(value: info.size).show}  ·  ${fmtRelative(info.lastModified)}';
                return Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: MeowFont.footnote, color: cs.onSurfaceVariant),
                );
              },
            ),
            const SizedBox(height: 4),
            Text(
              bundled ? _bundleMRSUrl : url!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: MeowFont.mono(size: MeowFont.caption, color: cs.outline),
            ),
          ],
        ],
      ),
    );
  }
}

/// 改下载地址：多行输入框；和缺省地址不同时多一个「恢复缺省」。
class _GeoUrlDialog extends StatefulWidget {
  const _GeoUrlDialog({required this.title, required this.url, this.defaultValue});

  final String title;
  final String url;
  final String? defaultValue;

  @override
  State<_GeoUrlDialog> createState() => _GeoUrlDialogState();
}

class _GeoUrlDialogState extends State<_GeoUrlDialog> {
  late final _c = TextEditingController(text: widget.url);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _c.value.text;
    if (url.isEmpty) return;
    Navigator.of(context).pop(url);
  }

  @override
  Widget build(BuildContext context) {
    final def = widget.defaultValue;
    return AlertDialog(
      scrollable: true,
      title: Text('${widget.title} 下载地址'),
      content: TextField(
        controller: _c,
        minLines: 1,
        maxLines: 5,
        autocorrect: false,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        if (def != null && _c.value.text != def)
          TextButton(onPressed: () => Navigator.of(context).pop(def), child: const Text('恢复缺省')),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
