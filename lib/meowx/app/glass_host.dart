import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../glass/liquid_glass.dart';
import '../state/meow_settings.dart';
import '../state/status.dart';
import '../theme/glass.dart';

/// 全 App 唯一的玻璃宿主：包在 Navigator 外面（application.dart 的 MaterialApp.builder），
/// 这样底栏、页面右上角的圆钮、从根 Navigator 弹出的菜单与「我的」设置卡片都在同一个宿主里——
/// 宿主每帧把各块玻璃背后的画面缩小后截一次、所有玻璃共用（见 ../glass/liquid_glass_capture.dart），不给每块挂实时模糊。
/// 一个玻璃面板只能有一个宿主包着，所以壳（meow_root.dart）里不再另放。
///
/// 开不开：手机上底栏恒为玻璃（两种主题都保留），宿主恒开；宽屏没有底栏，只有液态玻璃主题且玻璃控件可用时才开
/// （经典主题的宽屏仍然一层都不多）。玻璃控件（[MeowGlassControls]）= 液态玻璃主题，且不是低端机、系统没开高对比度。
class MeowGlassHost extends ConsumerStatefulWidget {
  const MeowGlassHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MeowGlassHost> createState() => _MeowGlassHostState();
}

class _MeowGlassHostState extends ConsumerState<MeowGlassHost> {
  @override
  void initState() {
    super.initState();
    unawaited(MeowGlassDevice.probe().then((_) {
      if (mounted) setState(() {});
    }));
  }

  @override
  Widget build(BuildContext context) {
    final glassTheme = ref.watch(meowLookProvider.select((l) => l.glass));
    final wide = ref.watch(isWideLayoutProvider);
    final controls =
        glassTheme && !MeowGlassDevice.lowEnd && !(MediaQuery.maybeHighContrastOf(context) ?? false);
    final host = !wide || controls;
    return MeowGlassControls(
      enabled: controls,
      child: LiquidGlassScope(
        enabled: host,
        quality: LiquidGlassQuality.standard,
        child: LiquidGlassHost(enabled: host, child: widget.child),
      ),
    );
  }
}

/// 低端机判断（只问一次）：Android 系统标为低内存设备，或物理内存不到 [MeowGlassMetrics.lowRamMb]。其它平台不算。
abstract final class MeowGlassDevice {
  static bool _lowEnd = false;
  static Future<void>? _probing;

  static bool get lowEnd => _lowEnd;

  @visibleForTesting
  static set debugLowEnd(bool value) => _lowEnd = value;

  static Future<void> probe() => _probing ??= () async {
    if (!system.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      _lowEnd = info.isLowRamDevice || (info.physicalRamSize > 0 && info.physicalRamSize < MeowGlassMetrics.lowRamMb);
    } catch (e) {
      commonPrint.log('glass device probe failed: $e');
    }
  }();
}
