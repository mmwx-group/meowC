import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' show dirname, join;

import '../../../theme/m3.dart';
import '../../me/me_kit.dart';

/// 程序目录里的 WindowsLoopbackManager.exe（MeowX 不随包分发这个来源不明的第三方工具；用户自己放进去才有）。
String get _loopbackManagerPath => join(dirname(Platform.resolvedExecutable), 'WindowsLoopbackManager.exe');

/// 回环解锁工具在不在：只在 Windows 且这个文件存在时才放 [LoopbackRow]（同原 Bettbox「工具」页的条件）。
bool get loopbackManagerExists => File(_loopbackManagerPath).existsSync();

/// 回环解锁工具（只 Windows，原 Bettbox「工具」页的 `_LoopbackItem`）：点了以管理员身份运行 WindowsLoopbackManager.exe。
/// 放不放由调用方按 `system.isWindows && loopbackManagerExists` 决定。
class LoopbackRow extends StatelessWidget {
  const LoopbackRow({super.key});

  @override
  Widget build(BuildContext context) {
    return MeRow(
      label: '回环解锁工具',
      subtitle: '用于 UWP 回环解锁',
      trailing: Icon(Icons.open_in_new_rounded, size: 16, color: context.cs.onSurfaceVariant),
      onTap: () => windows?.runas('"$_loopbackManagerPath"', '', showWindow: true),
    );
  }
}
