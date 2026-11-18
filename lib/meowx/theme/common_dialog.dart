import 'dart:math';

import 'package:bett_box/providers/app.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 通用对话框（原 Bettbox 的 lib/widgets/dialog.dart，2026-11-17 删掉 Bettbox 界面时挪进来、只留它）：
/// 底层（controller / state 的提示框、Linux 管理员密码）和几处搬过来的页面还在用，接口不变。
/// 外观交给主题里的 M3 dialogTheme；电视上返回键先收起输入框的焦点再关（同原版）。
class CommonDialog extends ConsumerWidget {
  final String title;
  final Widget? titleTrailing;
  final Widget? child;
  final List<Widget>? actions;
  final EdgeInsets? padding;
  final bool overrideScroll;
  final Color? backgroundColor;

  const CommonDialog({
    super.key,
    required this.title,
    this.titleTrailing,
    this.actions,
    this.child,
    this.padding,
    this.overrideScroll = false,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = ref.watch(viewSizeProvider);
    final isTv = globalState.isAndroidTV;
    return PopScope(
      canPop: !isTv,
      onPopInvokedWithResult: !isTv
          ? null
          : (didPop, result) {
              if (didPop) return;
              if (dismissTvInputFocus()) return;
              if (ModalRoute.of(context)?.isCurrent != true) return;
              Navigator.of(context).pop();
            },
      child: AlertDialog(
        title: titleTrailing == null
            ? Text(title)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(title)),
                  const SizedBox(width: 8),
                  titleTrailing!,
                ],
              ),
        actions: actions,
        contentPadding: padding,
        backgroundColor: backgroundColor,
        content: Container(
          constraints: BoxConstraints(maxHeight: min(size.height - 40, 500), maxWidth: 300),
          width: size.width - 40,
          child: !overrideScroll ? SingleChildScrollView(child: child) : child,
        ),
      ),
    );
  }
}

/// 电视上焦点在输入框 / 滑杆里时，返回键先把焦点收回到所在的范围（不关对话框）；不是电视或不在输入框里返回 false。
bool dismissTvInputFocus() {
  if (!globalState.isAndroidTV) return false;
  final node = FocusManager.instance.primaryFocus;
  if (node == null) return false;
  final context = node.context;
  if (context == null) return false;
  final isInput =
      context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null ||
      context.widget is Slider ||
      context.findAncestorWidgetOfExactType<Slider>() != null;
  if (!isInput) return false;
  node.enclosingScope?.requestScopeFocus();
  return true;
}
