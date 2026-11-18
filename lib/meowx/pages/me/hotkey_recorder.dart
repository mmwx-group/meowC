// 录全局快捷键的对话框（原 Bettbox 的 lib/views/hotkey.dart 里的 HotKeyRecorder，2026-11-17 删掉 Bettbox 界面时挪进来；
// 按键方块换成 M3 的浅底圆角块）。
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../theme/common_dialog.dart';

class HotKeyRecorder extends StatefulWidget {
  final HotKeyAction hotKeyAction;

  const HotKeyRecorder({super.key, required this.hotKeyAction});

  @override
  State<HotKeyRecorder> createState() => _HotKeyRecorderState();
}

class _HotKeyRecorderState extends State<HotKeyRecorder> {
  late ValueNotifier<HotKeyAction> hotKeyActionNotifier;

  @override
  void initState() {
    super.initState();
    hotKeyActionNotifier = ValueNotifier<HotKeyAction>(
      widget.hotKeyAction.copyWith(),
    );
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  bool _handleKeyEvent(KeyEvent keyEvent) {
    if (keyEvent is KeyUpEvent) return false;
    final keys = HardwareKeyboard.instance.physicalKeysPressed;

    final key = keyEvent.physicalKey;

    final modifiers = KeyboardModifier.values
        .where(
          (e) =>
              e.physicalKeys.any(keys.contains) &&
              !e.physicalKeys.contains(key),
        )
        .toSet();
    hotKeyActionNotifier.value = hotKeyActionNotifier.value.copyWith(
      modifiers: modifiers,
      key: key.usbHidUsage,
    );
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  void _handleRemove() {
    Navigator.of(context).pop();
    globalState.appController.updateOrAddHotKeyAction(
      hotKeyActionNotifier.value.copyWith(modifiers: {}, key: null),
    );
  }

  void _handleConfirm() {
    Navigator.of(context).pop();
    final config = globalState.config;
    final currentHotkeyAction = hotKeyActionNotifier.value;
    if (currentHotkeyAction.key == null ||
        currentHotkeyAction.modifiers.isEmpty) {
      globalState.showMessage(
        title: appLocalizations.tip,
        message: TextSpan(text: appLocalizations.inputCorrectHotkey),
        cancelable: false,
      );
      return;
    }
    final hotKeyActions = config.hotKeyActions;
    final index = hotKeyActions.indexWhere(
      (item) =>
          item.key == currentHotkeyAction.key &&
          keyboardModifierListEquality.equals(
            item.modifiers,
            currentHotkeyAction.modifiers,
          ),
    );
    if (index != -1) {
      globalState.showMessage(
        title: appLocalizations.tip,
        message: TextSpan(text: appLocalizations.hotkeyConflict),
        cancelable: false,
      );
      return;
    }
    globalState.appController.updateOrAddHotKeyAction(currentHotkeyAction);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (_, _) {
        return KeyEventResult.handled;
      },
      autofocus: true,
      child: CommonDialog(
        title: Intl.message('action_${widget.hotKeyAction.action.name}'),
        actions: [
          TextButton(
            onPressed: () {
              _handleRemove();
            },
            child: Text(appLocalizations.remove),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              _handleConfirm();
            },
            child: Text(appLocalizations.confirm),
          ),
        ],
        child: ValueListenableBuilder(
          valueListenable: hotKeyActionNotifier,
          builder: (_, hotKeyAction, _) {
            final key = hotKeyAction.key;
            final modifiers = hotKeyAction.modifiers;
            return SizedBox(
              width: dialogCommonWidth,
              child: key != null
                  ? Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final modifier in modifiers)
                          KeyboardKeyBox(
                            keyboardKey: modifier.physicalKeys.first,
                          ),
                        if (modifiers.isNotEmpty)
                          Text('+', style: context.textTheme.titleMedium),
                        KeyboardKeyBox(keyboardKey: PhysicalKeyboardKey(key)),
                      ],
                    )
                  : Text(
                      appLocalizations.pressKeyboard,
                      style: context.textTheme.titleMedium,
                    ),
            );
          },
        ),
      ),
    );
  }
}

class KeyboardKeyBox extends StatelessWidget {
  final KeyboardKey keyboardKey;

  const KeyboardKeyBox({super.key, required this.keyboardKey});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Text(keyboardKey.label, style: const TextStyle(fontSize: 16)),
    );
  }
}
