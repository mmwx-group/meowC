import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/mesh.dart';
import '../../state/meow_settings.dart';
import '../../state/status.dart';
import '../../theme/haptics.dart';
import '../../theme/m3.dart';
import '../../theme/mesh_glyph.dart';
import 'info_cards.dart';
import '../settings/networking_page.dart';

// 这个卡片可能放在宽屏首页的 IntrinsicHeight 里（见 dashboard_page.dart），不要用 LayoutBuilder。

/// 首页的「喵窝」卡（整行）：开关 + 状态（已连接 / 连接中 / 失败原因）+ 本机地址 + 在线几台；点卡片进「组网」页。
/// 在管理员账号（主控说可用 / 没开）或喵窝开着时显示（[meshVisibleProvider]）。
/// 卡片看得见、App 在前台时每 30 秒问一次主控（刚打开 / 入网后的 90 秒由 MeshController 自己加快）。
class HomeMeshCard extends ConsumerStatefulWidget {
  const HomeMeshCard({super.key, this.borderRadius = const BorderRadius.all(Radius.circular(MeowShape.xl)), this.single = false});

  /// 没有并排的「代理应用」：横向一行
  final bool single;

  /// 和「代理应用」并排时左下角收小（画布稿）
  final BorderRadius borderRadius;

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
    final cs = context.cs;
    final name = meowNestName(context);
    final state = ref.watch(meshProvider);
    final mesh = ref.watch(meowSettingProvider.select((s) => s.mesh));
    final running = ref.watch(isRunningProvider);
    final phase = meshPhase(enabled: mesh.enabled, running: running, state: state, fallbackId: mesh.nodeId);
    // 已连接时第二行带本机地址（入网后才有）
    final address = phase == MeshPhase.connected ? state.selfAddress(mesh.nodeId) : '';
    final text = meshPhaseText(phase, state, fallbackId: mesh.nodeId);
    final busy = _switching || state.busy || state.enrolling;
    // 和首页其它普通卡片同一种底色（2026-11-17 用户要求：开着时不再换成第三色 / 出错色容器），状态看第二行文字与开关
    final (bg, fg) = (cs.card, cs.onSurface);
    return HomeFeatureTile(
      icon: MeshGlyph(size: 28, color: fg),
      title: name,
      subtitle: address.isEmpty ? text : '$address · $text',
      bg: bg,
      fg: fg,
      borderRadius: widget.borderRadius,
      single: widget.single,
      onTap: () => BaseNavigator.push(context, const NetworkingPage()),
      trailing: busy
          ? Padding(
              padding: const EdgeInsets.only(right: 14),
              child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fg)),
            )
          : Switch(
              value: mesh.enabled,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: MeowHaptics.onSwitch((on) => unawaited(_toggle(on))),
            ),
    );
  }
}
