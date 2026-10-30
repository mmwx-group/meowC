import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 震动反馈（与 iOS 的 MeowHaptics 同一套规则）：用在有意义的动作上——测速、电源键、切出站模式、选节点、
/// 刷新订阅 / 出口 IP；2026-10-30 用户又要「打开开关、点 dock 按钮等等」也震：拨开关（[onSwitch]）、换分段（[MeowSegment]）、
/// 换筛选胶囊 / 代理组、展开收起代理组。普通按钮（进子页、关弹窗）不震。底栏切页的 selectionClick 在 meow_dock / meow_root 里另有。
/// 安卓走 View.performHapticFeedback，系统「触摸反馈」关着就不震，所以不另设开关。
abstract final class MeowHaptics {
  /// 安卓 API 级别（壳启动时填，见 MeowRoot）：成功 / 失败那两种（CONFIRM / REJECT）Android 11（30）起才有，
  /// 更低的版本 Flutter 什么都不做，退回中 / 重两档。0 = 不知道，按新系统算
  static int androidSdk = 0;

  /// 轻：开始测速、停止测速、刷新
  static void tap() => _play(HapticFeedback.lightImpact);

  /// 中：电源键连接 / 断开
  static void toggle() => _play(HapticFeedback.mediumImpact);

  /// 选择：切出站模式、选节点
  static void select() => _play(HapticFeedback.selectionClick);

  /// 等了一会儿的事做完了（网络测速测完）
  static void success() => _play(_notification ? HapticFeedback.successNotification : HapticFeedback.mediumImpact);

  /// 等了一会儿的事失败了（网络测速失败、没能开始）
  static void error() => _play(_notification ? HapticFeedback.errorNotification : HapticFeedback.heavyImpact);

  /// 开关：包住 Switch 的 onChanged，用户拨动时轻震一下（null 照样是禁用）
  static ValueChanged<bool>? onSwitch(ValueChanged<bool>? onChanged) => onChanged == null
      ? null
      : (v) {
          tap();
          onChanged(v);
        };

  static bool get _notification =>
      defaultTargetPlatform != TargetPlatform.android || androidSdk == 0 || androidSdk >= 30;

  // 只有手机震：Windows 引擎不认这个调用，调了只会多一个 MissingPluginException
  static void _play(Future<void> Function() haptic) {
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(haptic());
    }
  }
}
