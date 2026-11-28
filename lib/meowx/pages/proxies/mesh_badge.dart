import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/mesh.dart';
import '../../state/mesh_relay.dart';
import '../../state/meow_settings.dart';
import '../../theme/m3.dart';
import '../../theme/meow_dialog.dart';
import '../../theme/mesh_glyph.dart';
import '../../theme/tokens.dart';
import '../settings/mesh_relay_pages.dart';
import '../settings/mesh_relay_text.dart';

/// 节点格上的「喵窝」小标（喵窝白名单直连，规格 B4）：订阅里的白名单节点（`_mmwx-mesh`）这次经喵窝拨号时画喵窝图标，
/// 点开看链路：连到哪台服务器、现在直连 / 经哪台设备中继 / 经中继服务器（同 MeowX iOS 的 MeshViaBadge）。
/// 不是这种节点时什么都不画、不占位。
class MeshViaBadge extends ConsumerWidget {
  const MeshViaBadge(this.nodeName, {super.key, this.size = 14});

  final String nodeName;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final via = ref.watch(meshWhitelistNodesProvider.select((s) => s.contains(nodeName)));
    if (!via) return const SizedBox.shrink();
    final mm = context.mm;
    final t = MeshRelayText.of(context);
    return Builder(
      builder: (ctx) => Tooltip(
        message: t.viaBadge,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showMeowPopover<void>(
            ctx,
            title: nodeName,
            titleLeading: MeshGlyph(size: 16, color: mm.accent),
            width: 300,
            builder: (_) => MeshViaDetail(nodeName: nodeName),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: MeshGlyph(size: size, color: mm.accent),
          ),
        ),
      ),
    );
  }
}

/// 气泡里此刻怎么走（决定图标与颜色）。
enum MeshViaKind { direct, peerRelay, derp, idle, unavailable }

/// 气泡的内容（纯值，可单测）。
@immutable
class MeshViaInfo {
  const MeshViaInfo({
    required this.target,
    required this.ip,
    required this.kind,
    required this.path,
    this.details = const [],
    this.panel,
  });

  /// 服务器名（主控 mesh status 的 servers 按喵窝地址对上；对不上就是地址）
  final String target;

  /// 服务器的喵窝地址
  final String ip;
  final MeshViaKind kind;

  /// 大字一句：直连 / 经 X 中继 / 经设备中继 / 经中继服务器 Y / 空闲
  final String path;

  /// 小字（等宽）：中继地址 / 对端地址 / 中继服务器区域 / 空闲时的说明
  final List<String> details;

  /// 本机认不出中继设备、主控认得出时补的一句「主控记录：经 X 中继」
  final String? panel;
}

/// 节点（server 是喵窝地址 [ip]）的链路：路径类型以本机内核的实时值为准，名字从主控补（Design/mesh-peer-relay.md §2.4）。
MeshViaInfo meshViaInfo(MeshRelayText t, {required String ip, required MeshState mesh, MeshPathsSnapshot? paths, int? selfId}) {
  var target = ip;
  for (final s in mesh.servers) {
    if (s.meshIp == ip) {
      target = s.name;
      break;
    }
  }
  final engine = mesh.engine;
  if (engine == null || !engine.running) {
    return MeshViaInfo(target: target, ip: ip, kind: MeshViaKind.unavailable, path: t.viaNotRunning);
  }
  final peer = engine.peerFor(ip: ip);
  if (peer == null) {
    return MeshViaInfo(target: target, ip: ip, kind: MeshViaKind.unavailable, path: t.viaNotInList);
  }
  // 本机在主控设备列表里的编号；列表还没拿到时用内核里的本机编号与地址
  final self = mesh.selfDevice(selfId);
  final myId = self?.id ?? engine.self?.id;
  final myIp = self?.ipv4 ?? engine.self?.addresses.firstWhere((a) => !a.contains(':'), orElse: () => '') ?? '';
  final link = myId == null ? null : paths?.linkToIp(selfId: myId, selfIp: myIp, ip: ip);
  final view = meshPathView(local: peer, link: link, paths: paths);
  if (view == null || view.kind == MeshPathKind.idle) {
    return MeshViaInfo(target: target, ip: ip, kind: MeshViaKind.idle, path: t.pathIdle, details: [t.viaIdleNote]);
  }
  final path = meshPathLabel(t, view);
  return switch (view.kind) {
    MeshPathKind.peerRelay => MeshViaInfo(
      target: target,
      ip: ip,
      kind: MeshViaKind.peerRelay,
      path: path,
      // 「ip:port:vni:N」只留地址，VNI 对用户没意义
      details: [t.viaRelayAddr(view.relayAddr.isNotEmpty ? view.relayAddr : peer.peerRelay)],
      panel: view.relayNamedByPanel ? t.viaPanelRecord(t.pathViaRelay(view.relayName)) : null,
    ),
    MeshPathKind.direct => MeshViaInfo(
      target: target,
      ip: ip,
      kind: MeshViaKind.direct,
      path: path,
      details: [if (peer.curAddr.isNotEmpty) t.viaPeerAddr(peer.curAddr)],
    ),
    _ => MeshViaInfo(
      target: target,
      ip: ip,
      kind: MeshViaKind.derp,
      path: path,
      details: [if (view.derpRegion.isNotEmpty) t.viaDerpRegion(view.derpRegion)],
    ),
  };
}

/// 「喵窝」小标的气泡：连到哪台服务器 → 现在怎么走（大字，带图标与颜色）→ 地址小字 → 说明。打开时问一次内核与主控汇总。
class MeshViaDetail extends ConsumerStatefulWidget {
  const MeshViaDetail({super.key, required this.nodeName});

  final String nodeName;

  @override
  ConsumerState<MeshViaDetail> createState() => _MeshViaDetailState();
}

class _MeshViaDetailState extends ConsumerState<MeshViaDetail> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(ref.read(meshProvider.notifier).pollEngine());
      unawaited(ref.read(meshRelayProvider.notifier).refresh(force: true));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = MeshRelayText.of(context);
    final mm = context.mm;
    final cs = context.cs;
    final mesh = ref.watch(meshProvider);
    final paths = ref.watch(meshRelayProvider.select((s) => s.paths));
    final nodeId = ref.watch(meowSettingProvider.select((s) => s.mesh.nodeId));
    final ip = meshRuntime.whitelistServers[widget.nodeName] ?? '';
    final info = meshViaInfo(t, ip: ip, mesh: mesh, paths: paths, selfId: nodeId);
    final color = switch (info.kind) {
      MeshViaKind.direct => mm.good,
      MeshViaKind.peerRelay => mm.accent,
      MeshViaKind.unavailable => mm.down,
      _ => mm.t1,
    };
    final icon = switch (info.kind) {
      MeshViaKind.direct => Icons.swap_horiz_rounded,
      MeshViaKind.peerRelay => Icons.device_hub_rounded,
      MeshViaKind.derp => Icons.dns_rounded,
      MeshViaKind.idle => Icons.bedtime_rounded,
      MeshViaKind.unavailable => Icons.warning_amber_rounded,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(t.viaConnectTo, style: TextStyle(fontSize: MeowFont.caption, color: mm.t2)),
              Text(info.target, style: TextStyle(fontSize: MeowFont.footnote, fontWeight: FontWeight.w600, color: mm.t1)),
              if (info.ip.isNotEmpty && info.ip != info.target)
                SelectableText(info.ip, style: MeowFont.mono(size: MeowFont.caption, color: mm.t2)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(MeowShape.m),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      info.path,
                      style: TextStyle(fontSize: MeowFont.subheadline, fontWeight: FontWeight.w700, color: color, height: 1.3),
                    ),
                    for (final line in info.details) ...[
                      const SizedBox(height: 3),
                      SelectableText(line, style: MeowFont.mono(size: MeowFont.caption2, color: mm.t2)),
                    ],
                    if (info.panel case final panel?) ...[
                      const SizedBox(height: 3),
                      Text(panel, style: TextStyle(fontSize: MeowFont.caption2, color: mm.t2, height: 1.35)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(t.viaFooter, style: TextStyle(fontSize: MeowFont.caption, color: cs.onSurfaceVariant, height: 1.4)),
        ),
      ],
    );
  }
}
