import 'package:flutter/material.dart';

/// 高级 › 应用这几页共用的两个对话框：带校验 / 恢复默认的单行输入、二次确认。

/// 输入对话框：确定 = 返回输入框里的文字（可以是空串，与 Bettbox 的输入框一致）；
/// [resetValue] 不为 null 时多一个「恢复默认」，点了直接返回它；取消返回 null。
Future<String?> advPrompt(
  BuildContext context, {
  required String title,
  required String initial,
  String? hint,
  String? resetValue,
  FormFieldValidator<String>? validator,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PromptDialog(title: title, initial: initial, hint: hint, resetValue: resetValue, validator: validator),
);

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({required this.title, required this.initial, this.hint, this.resetValue, this.validator});

  final String title;
  final String initial;
  final String? hint;
  final String? resetValue;
  final FormFieldValidator<String>? validator;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          validator: widget.validator,
          decoration: InputDecoration(hintText: widget.hint),
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        if (widget.resetValue != null)
          TextButton(onPressed: () => Navigator.of(context).pop(widget.resetValue), child: const Text('恢复默认')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

/// 二次确认：点「确定」返回 true，取消 / 点外面返回 false。
Future<bool> advConfirm(BuildContext context, {required String title, required String message, String confirm = '确定'}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(confirm)),
      ],
    ),
  );
  return ok == true;
}
