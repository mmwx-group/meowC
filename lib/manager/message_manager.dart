import 'dart:async';
import 'dart:math';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';

class MessageManager extends StatefulWidget {
  final Widget child;

  const MessageManager({super.key, required this.child});

  @override
  State<MessageManager> createState() => MessageManagerState();
}

class MessageManagerState extends State<MessageManager> {
  final _messagesNotifier = ValueNotifier<List<CommonMessage>>([]);
  final List<CommonMessage> _bufferMessages = [];
  bool _pushing = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _messagesNotifier.dispose();
    super.dispose();
  }

  Future<void> message(
    String text, {
    VoidCallback? onAction,
    String? actionLabel,
    bool showCountdown = false,
  }) async {
    if (_messagesNotifier.value.any((m) => m.text == text) ||
        _bufferMessages.any((m) => m.text == text)) {
      return;
    }

    final commonMessage = CommonMessage(
      id: utils.uuidV4,
      text: text,
      onAction: onAction,
      actionLabel: actionLabel,
      showCountdown: showCountdown,
    );
    _bufferMessages.add(commonMessage);
    await _showMessage();
  }

  Future<void> _showMessage() async {
    if (_pushing) return;
    _pushing = true;
    while (_bufferMessages.isNotEmpty) {
      final commonMessage = _bufferMessages.removeAt(0);
      _messagesNotifier.value = List.from(_messagesNotifier.value)
        ..add(commonMessage);
      await Future.delayed(const Duration(seconds: 1));
      Future.delayed(
        commonMessage.duration,
        () => _handleRemove(commonMessage),
      );
      if (_bufferMessages.isEmpty) _pushing = false;
    }
  }

  void _handleRemove(CommonMessage commonMessage) {
    _messagesNotifier.value = List<CommonMessage>.from(_messagesNotifier.value)
      ..remove(commonMessage);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        ValueListenableBuilder(
          valueListenable: _messagesNotifier,
          builder: (_, messages, _) {
            // 提示条的进出：淡入淡出 + 轻微缩放（原 Bettbox 的 FadeThroughBox，2026-11-17 删掉 Bettbox 界面时换成 AnimatedSwitcher）
            return Container(
              margin: EdgeInsets.only(
                top: kToolbarHeight + 8,
                left: 12,
                right: 12,
              ),
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween(begin: 0.92, end: 1.0).animate(animation),
                    child: child,
                  ),
                ),
                child: messages.isEmpty
                    ? SizedBox()
                    : LayoutBuilder(
                        key: Key(messages.last.id),
                        builder: (_, constraints) {
                          final message = messages.last;
                          // MeowX：M3 snackbar 的配色（inverseSurface 底、onInverseSurface 字、按钮 inversePrimary）
                          return Card(
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(16.0),
                              ),
                            ),
                            elevation: 6,
                            color: context.colorScheme.inverseSurface,
                            child: Container(
                              width: min(constraints.maxWidth, 500),
                              padding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (message.showCountdown)
                                    _CountdownWidget(
                                      duration: message.duration,
                                    ),
                                  Expanded(
                                    child: Text(
                                      message.text,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: context
                                            .colorScheme
                                            .onInverseSurface,
                                      ),
                                    ),
                                  ),
                                  if (message.actionLabel != null &&
                                      message.onAction != null) ...[
                                    const SizedBox(width: 8),
                                    TextButton(
                                      onPressed: () {
                                        _handleRemove(message);
                                        message.onAction?.call();
                                      },
                                      style: TextButton.styleFrom(
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        foregroundColor:
                                            context.colorScheme.inversePrimary,
                                      ),
                                      child: Text(message.actionLabel!),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _CountdownWidget extends StatefulWidget {
  final Duration duration;

  const _CountdownWidget({required this.duration});

  @override
  State<_CountdownWidget> createState() => _CountdownWidgetState();
}

class _CountdownWidgetState extends State<_CountdownWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late int _totalSeconds;

  @override
  void initState() {
    super.initState();
    _totalSeconds = widget.duration.inSeconds;
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = context.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: 24,
        height: 24,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final remaining = (_totalSeconds * (1 - _controller.value)).ceil();
            final currentSecond = remaining > 0 ? remaining : 1;

            return Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: 1 - _controller.value,
                  strokeWidth: 2,
                  backgroundColor: primaryColor.withAlpha(26),
                  valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                ),
                Text(
                  '$currentSecond',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: primaryColor,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
