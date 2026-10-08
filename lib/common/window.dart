import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/meowx/state/window_placement.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class Window {
  Future<void> init() async {
    final props = globalState.config.windowProps;
    if (system.isWindows) {
      protocol.register('clash');
      protocol.register('clashmeta');
      protocol.register('miaomiaowu');
    }
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = WindowOptions(
      size: Size(props.width, props.height),
      minimumSize: const Size(900, 600),   // MeowX：图标栏 84 + 左栏 360 + 详情需要的最小宽度（≥ 1000 才是完整侧栏）
    );
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setAlwaysOnTop(props.isPinned);
    if (!system.isMacOS) {
      // MeowX：先定尺寸，否则下面居中按的是 runner 建窗时的默认 1280×720，窗口会偏右下
      await windowManager.setSize(Size(props.width, props.height));
      final left = props.left;
      final top = props.top;
      if (left == null || top == null || (left == 0 && top == 0)) {
        await windowManager.setAlignment(Alignment.center);
      } else {
        // MeowX：多屏且缩放不一致时，存盘坐标 / 屏幕工作区 / setPosition 三者口径不同，按屏换算后再判断
        Offset? position;
        try {
          position = restoreWindowPosition(
            saved: Offset(left, top),
            size: Size(props.width, props.height),
            displays: await _displayAreas(),
            currentScale: windowManager.getDevicePixelRatio(),
          );
        } catch (_) {}
        if (position != null) {
          await windowManager.setPosition(position);
        } else {
          await windowManager.setAlignment(Alignment.center);
        }
      }
    }
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true);
    });
  }

  void updateMacOSBrightness(Brightness brightness) {
  }

  /// screen_retriever 的工作区（逻辑像素，按各屏自己的缩放）+ 缩放。
  Future<List<DisplayArea>> _displayAreas() async {
    final displays = await screenRetriever.getAllDisplays();
    return [
      for (final d in displays)
        if (d.visiblePosition != null)
          DisplayArea(
            d.visiblePosition! & (d.visibleSize ?? d.size),
            (d.scaleFactor ?? 1).toDouble(),
          ),
    ];
  }

  /// MeowX：窗口藏在托盘期间拔了显示器 / 改了分辨率，再显示时会停在已经不存在的屏幕上，这时挪回主屏居中。
  Future<void> _ensureOnScreen() async {
    if (system.isMacOS) return;
    try {
      final bounds = await windowManager.getBounds();
      final position = restoreWindowPosition(
        saved: bounds.topLeft,
        size: bounds.size,
        displays: await _displayAreas(),
        currentScale: windowManager.getDevicePixelRatio(),
      );
      if (position == null) await windowManager.setAlignment(Alignment.center);
    } catch (_) {}
  }

  Future<void> show() async {
    globalState.handleForeground();
    render?.resume();
    await _ensureOnScreen();
    await windowManager.show();
    await windowManager.focus();
    if (!system.isMacOS) {
      await windowManager.setSkipTaskbar(false);
    }
    await globalState.resumeForegroundUpdates();
    await globalState.appController.syncWakelockIfNeeded();
  }

  Future<bool> get isVisible async {
    return await windowManager.isVisible();
  }

  Future<bool> get isMinimized async {
    return await windowManager.isMinimized();
  }

  Future<void> close() async {
    try {
      await trayManager.destroy();
      commonPrint.log('The tray icon has been destroyed.');
    } catch (e) {
      commonPrint.log('Failed to destroy the tray icon: $e');
    }

    exit(0);
  }

  Future<void> hide() async {
    await windowManager.hide();
    if (!system.isMacOS) {
      await windowManager.setSkipTaskbar(true);
    }
    await globalState.handleBackground();
  }
}

final window = system.isDesktop ? Window() : null;