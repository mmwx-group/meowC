import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../glass/liquid_glass.dart';
import '../state/status.dart';
import '../state/ui_prefs.dart';
import '../theme/glass.dart';

/// 全 App 唯一的玻璃宿主：包在 Navigator 外面（application.dart 的 MaterialApp.builder），
/// 这样底栏、页面右上角圆钮、二级页返回钮与弹出层都在同一个宿主里共用一次截屏背景。
/// 底层卡片保持清透实底；切到「iOS 27 液态玻璃」主题时开启 [MeowGlassControls]，让顶栏圆钮与返回钮同样呈现与 Dock 一致的液态玻璃。
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
    final host = !ref.watch(isWideLayoutProvider);
    final ios27Glass = ref.watch(meowUiPrefsProvider.select((s) => s.isIos27Glass));
    return MeowGlassControls(
      enabled: host && ios27Glass && !MeowGlassDevice.lowEnd,
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
