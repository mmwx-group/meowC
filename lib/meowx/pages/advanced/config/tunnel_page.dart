import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/tokens.dart';
import '../../me/me_kit.dart';
import 'config_kit.dart';

/// 内核配置 › 流量转发隧道（对应 Bettbox lib/views/config/tunnel.dart）：每条 = 网络协议 + 监听地址 + 目标地址 + 可选代理。
class CoreTunnelPage extends ConsumerWidget {
  const CoreTunnelPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mm = context.mm;
    final tunnels = ref.watch(patchClashConfigProvider.select((s) => s.tunnels));
    void save(List<TunnelEntry> next) =>
        ref.read(patchClashConfigProvider.notifier).updateState((s) => s.copyWith(tunnels: next));
    return MeSubPage.list(
      title: '流量转发',
      actions: [
        CcResetButton(onReset: () => save(defaultTunnel)),
        CcAddButton(onTap: () => _edit(context, onSave: (t) => save([...tunnels, t]))),
      ],
      children: [
        MeSection(
          children: [
            if (tunnels.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                child: Text(
                  '暂无数据，点右上角「+」添加',
                  style: TextStyle(fontSize: MeowFont.subheadline, color: mm.t2),
                ),
              ),
            for (final (i, t) in tunnels.indexed)
              InkWell(
                onTap: () => _edit(context, tunnel: t, onSave: (n) => save(List<TunnelEntry>.from(tunnels)..[i] = n)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.displayValue,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: MeowFont.mono(size: MeowFont.subheadline, color: mm.t1),
                        ),
                      ),
                      IconButton(
                        tooltip: '删除',
                        icon: Icon(Icons.close_rounded, size: 18, color: mm.t2),
                        onPressed: () => save(List<TunnelEntry>.from(tunnels)..removeAt(i)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const MeCaption('把本机的一个端口转发到目标地址，例如 tcp/udp,127.0.0.1:6553,114.114.114.114:53,proxy。'),
      ],
    );
  }

  Future<void> _edit(BuildContext context, {TunnelEntry? tunnel, required void Function(TunnelEntry) onSave}) =>
      showDialog<void>(
        context: context,
        builder: (_) => _TunnelDialog(tunnel: tunnel, onSave: onSave),
      );
}

/// 添加 / 编辑一条转发。网络协议按逗号拆分；监听地址与目标地址都不能为空（同 Bettbox，只是错误提示写在输入框下）。
class _TunnelDialog extends StatefulWidget {
  const _TunnelDialog({this.tunnel, required this.onSave});

  final TunnelEntry? tunnel;
  final void Function(TunnelEntry) onSave;

  @override
  State<_TunnelDialog> createState() => _TunnelDialogState();
}

class _TunnelDialogState extends State<_TunnelDialog> {
  late final _network = TextEditingController(text: widget.tunnel?.network?.join(', ') ?? '');
  late final _address = TextEditingController(text: widget.tunnel?.address ?? '');
  late final _target = TextEditingController(text: widget.tunnel?.target ?? '');
  late final _proxy = TextEditingController(text: widget.tunnel?.proxyName ?? '');
  String? _addressErr, _targetErr;

  @override
  void dispose() {
    for (final c in [_network, _address, _target, _proxy]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final network = _network.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final address = _address.text.trim();
    final target = _target.text.trim();
    final proxy = _proxy.text.trim();
    if (address.isEmpty || target.isEmpty) {
      setState(() {
        _addressErr = address.isEmpty ? ccEmptyTip('监听地址') : null;
        _targetErr = target.isEmpty ? ccEmptyTip('目标地址') : null;
      });
      return;
    }
    widget.onSave(
      TunnelEntry(
        id: widget.tunnel?.id ?? utils.uuidV4,
        network: network.isEmpty ? null : network,
        address: address,
        target: target,
        proxyName: proxy.isEmpty ? null : proxy,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.tunnel == null ? '添加转发' : '编辑转发'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        TextField(
          controller: _network,
          autofocus: true,
          decoration: const InputDecoration(labelText: '网络协议', hintText: '例如: tcp, udp'),
        ),
        TextField(
          controller: _address,
          decoration: InputDecoration(labelText: '监听地址', hintText: '例如: 127.0.0.1:6553', errorText: _addressErr),
        ),
        TextField(
          controller: _target,
          decoration: InputDecoration(labelText: '目标地址', hintText: '例如: 114.114.114.114:53', errorText: _targetErr),
        ),
        TextField(
          controller: _proxy,
          decoration: const InputDecoration(labelText: '代理名称', hintText: '例如: proxy (可选)'),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}
