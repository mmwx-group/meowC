import 'package:bett_box/common/common.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/dialog.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app/strings.dart';
import 'android_updater.dart';
import 'update_manifest.dart';
import 'windows_updater.dart';

/// Windows 一键更新入口：进度弹窗（百分比 + MB + 取消）→ 下载校验 → 安装包静默装 / 便携版换文件 → 退出 App，由脚本重启。
/// 更新流程由弹窗自己跑、自己用自己的 context 收起（不动导航栈里别的页面）：失败把错误 pop 出来，取消 pop null。
/// 失败时报错并给「去下载页」；取消静默收起。
Future<void> runWindowsUpdate(UpdateFile file) async {
  final updater = WindowsUpdater(
    workRoot: await appPath.tempPath,
    exitApp: globalState.appController.handleExit,
  );
  final error = await globalState.showCommonDialog<Object>(
    dismissible: false,
    child: _UpdateProgressDialog(
      file: file,
      run: (progress, cancel) => updater.run(file, progress: progress, cancelToken: cancel),
    ),
  );
  if (error == null) return; // 脚本已拉起、App 正在退出；或用户取消
  await _showUpdateFailed('Windows', error);
}

/// Android App 内更新入口：进度弹窗下载并校验 APK → 交给系统安装器（弹窗随即收起）。
/// 还没允许「安装未知应用」时原生那边已打开设置页，这里留一个「继续安装」，开完开关回来点它直接装下好的包。
Future<void> runAndroidUpdate(UpdateFile file) async {
  final updater = AndroidUpdater(
    workRoot: await appPath.tempPath,
    install: (path) async => ApkInstallResult.parse(await app.installApk(path)),
  );
  Object? error = await globalState.showCommonDialog<Object>(
    dismissible: false,
    child: _UpdateProgressDialog(
      file: file,
      closeOnDone: true,
      run: (progress, cancel) => updater.run(file, progress: progress, cancelToken: cancel),
    ),
  );
  while (error is ApkInstallPermissionNeeded) {
    final apk = error.apk;
    final go = await globalState.showMessage(
      title: S.updateInstallPermissionTitle,
      message: TextSpan(text: S.updateInstallPermissionHint),
      confirmText: S.updateContinueInstall,
    );
    if (go != true) return;
    try {
      await updater.launch(apk);
      return;
    } catch (e) {
      error = e;
    }
  }
  if (error == null) return; // 已交给安装器；或用户取消
  await _showUpdateFailed('Android', error);
}

Future<void> _showUpdateFailed(String platform, Object error) async {
  commonPrint.log('$platform update failed: ${error.formatErrorLog}');
  final go = await globalState.showMessage(
    title: S.updateFailed,
    message: TextSpan(text: error is UpdateError ? error.message : error.formatError),
    confirmText: S.goDownloadPage,
  );
  if (go == true) globalState.openUrl(downloadPageUrl);
}

class _UpdateProgressDialog extends StatefulWidget {
  const _UpdateProgressDialog({required this.file, required this.run, this.closeOnDone = false});

  final UpdateFile file;
  final Future<void> Function(ValueNotifier<UpdateProgress> progress, CancelToken cancel) run;

  /// 跑完就收起（Android：安装器已调起，App 不退出）；Windows 跑完 App 正在退出，弹窗留到进程结束
  final bool closeOnDone;

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  final progress = ValueNotifier(UpdateProgress.zero);
  final cancel = CancelToken();

  static String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    progress.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    Object? error;
    try {
      await widget.run(progress, cancel);
      if (!widget.closeOnDone) return; // 脚本已拉起、App 正在退出，弹窗留到进程结束
    } on UpdateCancelled {
      // 用户取消：半成品已删，静默收起
    } catch (e) {
      error = e;
    }
    if (mounted) Navigator.of(context).pop(error);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateProgress>(
      valueListenable: progress,
      builder: (context, value, _) {
        final downloading = value.stage == UpdateStage.downloading;
        final fraction = value.fraction;
        final label = switch (value.stage) {
          UpdateStage.downloading => S.updateDownloading,
          UpdateStage.extracting => S.updateExtracting,
          UpdateStage.launching => switch (widget.file.kind) {
            'portable' => S.updateReplacing,
            'apk' => S.updateOpeningInstaller,
            _ => S.updateLaunching,
          },
        };
        return CommonDialog(
          title: S.updateTitle,
          actions: [
            TextButton(
              // 已经交给脚本 / 正在退出时不能再取消
              onPressed: value.stage == UpdateStage.launching ? null : cancel.cancel,
              child: Text(appLocalizations.cancel),
            ),
          ],
          child: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: context.textTheme.bodyMedium),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: downloading ? fraction : null),
                if (downloading) ...[
                  const SizedBox(height: 8),
                  Text(
                    fraction == null
                        ? '${_mb(value.received)} MB'
                        : '${(fraction * 100).toStringAsFixed(0)}%  ·  ${_mb(value.received)} / ${_mb(value.total)} MB',
                    style: context.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
