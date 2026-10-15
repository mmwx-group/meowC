import 'package:flutter/scheduler.dart';

/// 量动画卡不卡用的帧耗时记录：只在 `--dart-define=MEOWX_FRAME_LOG=true` 构建时生效，正式包里是编译期常量 false，整段被摇掉。
/// 每帧一行 `MEOWX_FRAME build=… raster=… total=…`（毫秒），用 `adb logcat -s flutter` 抓。
abstract final class FrameLog {
  static const enabled = bool.fromEnvironment('MEOWX_FRAME_LOG');

  static bool _installed = false;

  static void install() {
    if (!enabled || _installed) return;
    _installed = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final b = t.buildDuration.inMicroseconds / 1000;
      final r = t.rasterDuration.inMicroseconds / 1000;
      final total = t.totalSpan.inMicroseconds / 1000;
      // ignore: avoid_print
      print('MEOWX_FRAME build=${b.toStringAsFixed(2)} raster=${r.toStringAsFixed(2)} total=${total.toStringAsFixed(2)}');
    }
  }
}
