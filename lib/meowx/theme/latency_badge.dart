import 'package:flutter/material.dart';

import '../state/latency.dart';
import 'm3_kit.dart';

/// 延迟胶囊的色调：通 = ok、一般 = warn、慢 / 超时 = error，没测 / 测试中 = neutral（阈值按测速方式，见 [LatencyMode.thresholds]）。
M3Tone latencyTone(int? ms, LatencyMode mode) {
  switch (latencyStateOf(ms)) {
    case LatencyState.untested || LatencyState.testing:
      return M3Tone.neutral;
    case LatencyState.timeout:
      return M3Tone.error;
    case LatencyState.value:
      if (ms! >= 100000) return M3Tone.error;
      final (good, mid) = mode.thresholds;
      return ms <= good ? M3Tone.ok : (ms <= mid ? M3Tone.warn : M3Tone.error);
  }
}

/// 延迟胶囊（M3 色调容器）：首页当前节点、节点清单共用。文案同 [msStyle]（null「—」、0「…」、超时）。
class LatencyBadge extends StatelessWidget {
  const LatencyBadge({super.key, required this.ms, required this.mode, this.unit = true, this.fontSize = 13});

  final int? ms;
  final LatencyMode mode;
  final bool unit;
  final double fontSize;

  static String text(int? ms, {bool unit = true}) => switch (latencyStateOf(ms)) {
    LatencyState.untested => unit ? '— ms' : '—',
    LatencyState.testing => '…',
    LatencyState.timeout => '超时',
    LatencyState.value => ms! >= 100000 ? '超时' : (unit ? '$ms ms' : '$ms'),
  };

  @override
  Widget build(BuildContext context) => M3Badge(text(ms, unit: unit), tone: latencyTone(ms, mode), fontSize: fontSize);
}
