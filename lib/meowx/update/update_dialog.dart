import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/dialog.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app/strings.dart';
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
    child: _UpdateProgressDialog(file: file, updater: updater),
  );
  if (error == null) return; // 脚本已拉起、App 正在退出；或用户取消
  commonPrint.log('Windows update failed: ${error.formatErrorLog}');
  final go = await globalState.showMessage(
    title: S.updateFailed,
    message: TextSpan(text: error is UpdateError ? error.message : error.formatError),
    confirmText: S.goDownloadPage,
  );
  if (go == true) globalState.openUrl(downloadPageUrl);
}

class _UpdateProgressDialog extends StatefulWidget {
  const _UpdateProgressDialog({required this.file, required this.updater});

  final UpdateFile file;
  final WindowsUpdater updater;

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
      await widget.updater.run(widget.file, progress: progress, cancelToken: cancel);
      return; // 脚本已拉起、App 正在退出，弹窗留到进程结束
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
          UpdateStage.launching => widget.file.kind == 'portable' ? S.updateReplacing : S.updateLaunching,
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
