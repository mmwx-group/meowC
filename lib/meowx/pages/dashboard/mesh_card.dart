import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/mesh.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/glass_card.dart';
import '../../theme/haptics.dart';
import '../../theme/tokens.dart';
import '../../theme/widgets.dart';
import '../settings/networking_page.dart';

// 这个卡片可能放在宽屏首页的 IntrinsicHeight 里（见 dashboard_page.dart），不要用 LayoutBuilder。

/// 首页的「喵窝」卡（整行）：开关 + 状态（已连接 / 连接中 / 失败原因）+ 本机地址 + 在线几台；点卡片进「组网」页。
/// 在管理员账号（主控说可用 / 没开）或喵窝开着时显示（[meshVisibleProvider]）。
/// 卡片看得见、App 在前台时每 30 秒问一次主控（刚打开 / 入网后的 90 秒由 MeshController 自己加快）。
class HomeMeshCard extends ConsumerStatefulWidget {
  const HomeMeshCard({super.key, this.dense = false});
  final bool dense;

  @override
  ConsumerState<HomeMeshCard> createState() => _HomeMeshCardState();
}

class _HomeMeshCardState extends ConsumerState<HomeMeshCard> {
  Timer? _timer;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) unawaited(ref.read(meshProvider.notifier).tick(devicesEvery: const Duration(seconds: 15)));
    });
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && TickerMode.getValuesNotifier(context).value.enabled) {
        unawaited(ref.read(meshProvider.notifier).tick());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _toggle(bool on) async {
    if (_switching) return;
    final err = await switchNetworking(
      context,
      ref,
      on ? NetworkingMode.mesh : NetworkingMode.off,
      onStart: () => setState(() => _switching = true),
    );
    if (mounted) setState(() => _switching = false);
    if (err != null) globalState.showNotifier(err);
  }

  @override
  Widget build(BuildContext context) {
    final mm = context.mm;
    final dense = widget.dense;
    final name = meowNestName(context);
    final state = ref.watch(meshProvider);
    final mesh = ref.watch(meowSettingProvider.select((s) => s.mesh));
    final running = ref.watch(isRunningProvider);
    final phase = meshPhase(enabled: mesh.enabled, running: running, state: state, fallbackId: mesh.nodeId);
    final self = state.selfDevice(mesh.nodeId);
    final online = state.onlineOthers(mesh.nodeId);
    final statusColor = switch (phase) {
      MeshPhase.connected => mm.good,
      MeshPhase.failed => mm.slow,
      _ => mm.t2,
    };
    // 第二行：本机地址 · 在线几台（入网后才有）
    final detail = [
      if (phase == MeshPhase.connected && self != null && self.ipv4.isNotEmpty) self.ipv4,
      if (phase == MeshPhase.connected) '$online 台在线',
    ].join(' · ');
    final busy = _switching || state.busy || state.enrolling;
    return GlassCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      onTap: () => BaseNavigator.push(context, const NetworkingPage()),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: [
            IconTile(icon: Icons.lan_rounded, tint: mesh.enabled ? null : mm.t2),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: dense ? 14 : 15, fontWeight: FontWeight.w600, color: mm.t1),
                  ),
                  Row(
                    children: [
                      if (mesh.enabled) ...[StatusDot(color: statusColor, size: 6), const SizedBox(width: 5)],
                      Flexible(
                        child: Text(
                          meshPhaseText(phase, state, fallbackId: mesh.nodeId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: dense ? 11 : 12, color: mesh.enabled ? statusColor : mm.t2),
                        ),
                      ),
                    ],
                  ),
                  if (detail.isNotEmpty && phase == MeshPhase.connected)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MeowFont.mono(size: dense ? 11 : 12, color: mm.t2),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              Switch(
                value: mesh.enabled,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: MeowHaptics.onSwitch((on) => unawaited(_toggle(on))),
              ),
          ],
        ),
      ),
    );
  }
}
