import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android：第一次连上之后，App 还没被加入「忽略电池优化」就提示一次（只提示一次，点哪个都记下）。
/// 三星 One UI 等系统的省电策略会把后台 App 休眠 / 冻结，VPN 服务被限制后表现为用一阵子就没网；
/// 以前这个开关藏在「设置 › 高级 › 其他」里、从不主动提示（三星用户实报，同机 NekoBox 正常）。
const _kPromptShown = 'meowx.batteryOptimizationPromptShown';

bool _checking = false;

Future<void> maybePromptBatteryOptimization() async {
  if (!system.isAndroid || _checking) return;
  _checking = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kPromptShown) ?? false) return;
    if (await app.isIgnoringBatteryOptimizations()) {
      await prefs.setBool(_kPromptShown, true);
      return;
    }
    final context = globalState.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;   // 没有界面（只有服务在跑）：下次连上再说
    unawaited(prefs.setBool(_kPromptShown, true));
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('让 MeowX 在后台保持连接'),
        content: const Text(
          '部分手机的省电策略会把后台 App 休眠，连接用一阵子就断。建议允许 MeowX 不受电池优化限制。\n\n'
          '三星手机还请在「设置 › 电池 › 后台使用限制」里把 MeowX 加入「永不休眠的应用」，'
          '并在「设置 › 应用程序 › MeowX › 电池」里选「不受限制」。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('以后再说')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('去设置')),
        ],
      ),
    );
    if (go == true) await app.requestIgnoreBatteryOptimizations();
  } catch (e) {
    commonPrint.log('battery optimization prompt failed: $e');
  } finally {
    _checking = false;
  }
}
