// 列表停在底部时新内容到了自动跟到底（原 Bettbox 的 lib/widgets/scroll.dart 里的 ScrollToEndBox，2026-11-17 删掉 Bettbox 界面时挪进来）。
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

class ScrollToEndBox<T> extends StatefulWidget {
  final ScrollController controller;
  final List<T> dataSource;
  final Widget child;
  final bool enable;
  final bool reverse;
  final VoidCallback? onCancelToEnd;

  const ScrollToEndBox({
    super.key,
    required this.child,
    required this.controller,
    required this.dataSource,
    this.onCancelToEnd,
    this.enable = true,
    this.reverse = false,
  });

  @override
  State<ScrollToEndBox<T>> createState() => _ScrollToEndBoxState<T>();
}

class _ScrollToEndBoxState<T> extends State<ScrollToEndBox<T>> {
  final _equals = ListEquality<T>();
  var _isFastToEnd = false;

  Future<void> _handleTryToEnd() async {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted && widget.controller.hasClients) {
        final pos = widget.controller.position;
        final end = widget.reverse ? pos.maxScrollExtent : pos.minScrollExtent;
        if (pos.pixels != end) {
          await widget.controller.animateTo(
            end,
            duration: kThemeAnimationDuration,
            curve: Curves.easeOut,
          );
        }
      }
      completer.complete();
    });
    return completer.future;
  }

  @override
  void didUpdateWidget(ScrollToEndBox<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enable && !oldWidget.enable) {
      _isFastToEnd = true;
      _handleTryToEnd().then((_) => _isFastToEnd = false);
      return;
    }
    if (widget.enable &&
        !_equals.equals(oldWidget.dataSource, widget.dataSource)) {
      _handleTryToEnd();
    }
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<UserScrollNotification>(
        onNotification: (n) {
          if (!_isFastToEnd && widget.onCancelToEnd != null) {
            widget.onCancelToEnd!();
          }
          return false;
        },
        child: widget.child,
      );
}

