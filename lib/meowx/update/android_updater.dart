import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'update_manifest.dart';
import 'windows_updater.dart';

/// 系统安装器调起的结果（对应原生 `installApk` 的返回值）。
enum ApkInstallResult {
  /// 已交给系统安装器（之后装不装由用户在安装器里定）
  launched,

  /// 还没允许「安装未知应用」：已打开设置页，用户打开开关后再调一次
  needsPermission,

  /// 调不起安装器
  failed;

  static ApkInstallResult parse(String? raw) => switch (raw) {
    'ok' => launched,
    'permission' => needsPermission,
    _ => failed,
  };
}

/// 还没允许「安装未知应用」：包已经下好、校验过，[apk] 留着给用户开完开关后直接装。
class ApkInstallPermissionNeeded implements Exception {
  final File apk;

  ApkInstallPermissionNeeded(this.apk);
}

/// Android App 内更新：把清单里的 APK 下到缓存目录（边下边算 SHA-256，收完按 size + sha256 校验）→ 交给系统安装器。
/// 以前只打开下载地址让用户自己用浏览器下，下到半截的包小米安装器报「解析软件包时出现问题 packageInfo is null」（用户实报）。
/// 缓存目录里同名、校验通过的包直接复用（开完「安装未知应用」开关回来再点不用重下）；别的旧包先清掉。
class AndroidUpdater {
  /// 缓存目录（`getTemporaryDirectory()` = `Context.getCacheDir()`，FileProvider 的 `cache-path` 指向它下面的 [dirName]）
  final String workRoot;
  final Future<ApkInstallResult> Function(String path) install;
  final Dio? dio;
  final bool Function(String url) isTrusted;

  static const dirName = 'meowx-update';

  AndroidUpdater({
    required this.workRoot,
    required this.install,
    this.dio,
    this.isTrusted = isTrustedUpdateUrl,
  });

  Future<void> run(
    UpdateFile file, {
    required ValueNotifier<UpdateProgress> progress,
    CancelToken? cancelToken,
  }) async {
    if (file.kind != 'apk') throw UpdateError('不支持的包类型：${file.kind}');
    if (!isTrusted(file.url)) throw UpdateError('更新地址不受信任：${file.url}');
    final dir = Directory(p.join(workRoot, dirName));
    final name = file.name.isNotEmpty ? file.name : 'update.apk';
    final target = File(p.join(dir.path, name));
    File? apk;
    if (await target.exists()) {
      try {
        await verifyUpdateFile(target, file);
        apk = target;
      } on UpdateError {
        await target.delete();
      }
    }
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e.path != target.path) await e.delete(recursive: true);
      }
    }
    apk ??= await downloadUpdateFile(file, dir: dir.path, progress: progress, cancelToken: cancelToken, dio: dio);
    if (cancelToken?.isCancelled == true) throw UpdateCancelled();
    progress.value = const UpdateProgress(UpdateStage.launching, 0, 0);
    await launch(apk);
  }

  /// 把校验过的包交给安装器；没允许「安装未知应用」抛 [ApkInstallPermissionNeeded]。
  Future<void> launch(File apk) async {
    switch (await install(apk.path)) {
      case ApkInstallResult.launched:
        return;
      case ApkInstallResult.needsPermission:
        throw ApkInstallPermissionNeeded(apk);
      case ApkInstallResult.failed:
        throw UpdateError('无法打开系统安装器');
    }
  }
}
