import 'package:bett_box/models/meow.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

export 'package:bett_box/models/meow.dart' show LatencyMode;

/// 延迟三档颜色：≤良好 绿、≤一般 橙、否则红。
Color latencyColor(int ms, LatencyMode mode, MeowTokens mm) {
  final (good, mid) = mode.thresholds;
  if (ms <= good) return mm.good;
  if (ms <= mid) return mm.mid;
  return mm.slow;
}

/// 延迟值语义（沿用 Bettbox 的 delayMap）：null = 未测，0 = 测试中，<0 = 超时，>0 = 毫秒。
enum LatencyState { untested, testing, timeout, value }

LatencyState latencyStateOf(int? v) {
  if (v == null) return LatencyState.untested;
  if (v == 0) return LatencyState.testing;
  if (v < 0) return LatencyState.timeout;
  return LatencyState.value;
}

/// 延迟文案 + 颜色。沿用 Bettbox 的 delayMap 语义：null = 没测过，0 = 测试中，<0（或 ≥100000）= 超时；
/// 有值时按测速方式的三档上色（HTTPS 延迟 / 真连接 / TCPing 的阈值不同）。节点格、组摘要、首页当前节点共用。
(String, Color) msStyle(MeowTokens mm, int? ms, LatencyMode mode) {
  if (ms == null) return ('— ms', mm.t2);
  if (ms == 0) return ('…', mm.t2);
  if (ms < 0 || ms >= 100000) return ('超时', mm.slow);
  return ('$ms ms', latencyColor(ms, mode, mm));
}
