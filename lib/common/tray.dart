import 'dart:async';
import 'dart:io';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/proxies/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:restart_app/restart_app.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'common.dart';

class Tray {
  Timer? _debounceTimer;
  TrayState? _pendingState;
  bool _isUpdating = false;
  bool _pendingFocus = false;
  bool _pendingSilent = false;

  static const _debounceDelay = Duration(milliseconds: 300);

  Timer? _loadingTimer;
  int _loadingFrame = 0;
  final List<String> _loadingFrames = ['.', '..', '...'];

  // MeowX：Windows 上托盘菜单只会由右键 → popUpMenu() 弹出，状态变化时不必每次都整份重建原生菜单
  // （开了「托盘显示代理组」是 组 × 节点 项：建项、编码、原生逐项拷贝再 AppendMenu，全在界面线程，选一次节点要来两遍）。
  // 平时只记「菜单已落后」，等弹出前再建；菜单正开着时照旧立即更新（测速进度、勾选）。图标 / 提示不受影响，仍即时更新。
  // Linux / macOS 的菜单由系统直接弹出，必须预置，保持原样。
  bool _menuStale = false;
  TrayState? _menuState; // 原生菜单上一次是按哪份状态建的；null = 还没建过
  int _menuPopups = 0; // 正在弹出 / 已弹出、popUpMenu() 还没返回的次数

  /// 测试里顶替「是不是 Windows」（本机测不了真的 Windows 托盘）；正式运行恒为 null。
  @visibleForTesting
  bool? debugLazyMenu;

  bool get _deferMenu =>
      (debugLazyMenu ?? system.isWindows) &&
      _menuPopups == 0 &&
      !trayManager.isMenuOpen;

  Tray() {
    delayTestCoordinator.addListener(_handleDelayTestStateChanged);
  }

  void _handleDelayTestStateChanged() {
    if (system.isAndroid) return;
    unawaited(globalState.appController.updateTray(false, true));
  }

  bool _traySpeedEnabled = false;
  bool _trayTrafficActive = false;
  bool _isSpeedTitleVisible = false;
  Traffic _lastTraffic = Traffic();
  int? _lastDisplayedUpload;
  int? _lastDisplayedDownload;
  bool? _lastDisplayedActive;

  void dispose() {
    delayTestCoordinator.removeListener(_handleDelayTestStateChanged);
    _debounceTimer?.cancel();
    _loadingTimer?.cancel();
  }
  Future _updateSystemTray({
    required Brightness? brightness,
    required bool isStart,
    bool force = false,
  }) async {
    if (system.isAndroid) {
      return;
    }
    if (force) {
      await trayManager.destroy();
      _isSpeedTitleVisible = false;
      _lastDisplayedUpload = null;
      _lastDisplayedDownload = null;
      _lastDisplayedActive = null;
    }
    await trayManager.setIcon(
      utils.getTrayIconPath(
        brightness:
            brightness ??
            WidgetsBinding.instance.platformDispatcher.platformBrightness,
        isStart: isStart,
        invertTrayIcon:
            (system.isWindows || (system.isMacOS && !isStart)) &&
            globalState.config.themeProps.invertTrayIcon,
      ),
      isTemplate: system.isMacOS && isStart,
      id: AppIdentity.compactName,
    );
    if (system.isMacOS) {
      await trayManager.setActive(isStart);
    }
    if (!Platform.isLinux) {
      await trayManager.setToolTip(appName);
    }
  }

  Future<void> update({
    required TrayState trayState,
    bool focus = false,
    bool silent = false,
    bool force = false,
  }) async {
    if (system.isAndroid) {
      return;
    }

    _debounceTimer?.cancel();

    if (_isUpdating) {
      _pendingState = trayState;
      _pendingFocus = focus;
      _pendingSilent = silent;
      return;
    }

    if (force || focus) {
      await _doUpdate(trayState: trayState, focus: focus, silent: silent);
    } else if (silent) {
      _debounceTimer = Timer(const Duration(milliseconds: 50), () async {
        await _doUpdate(trayState: trayState, focus: focus, silent: silent);
      });
    } else {
      _debounceTimer = Timer(_debounceDelay, () async {
        await _doUpdate(trayState: trayState, focus: focus);
      });
    }
  }

  Future<void> _doUpdate({
    required TrayState trayState,
    bool focus = false,
    bool silent = false,
  }) async {
    if (_isUpdating) return;
    _isUpdating = true;

    try {
      _traySpeedEnabled = trayState.enableTraySpeed;
      _trayTrafficActive =
          trayState.isStart && (trayState.systemProxy || trayState.tunEnable);
      if (!silent && !Platform.isLinux) {
        await _updateSystemTray(
          brightness: trayState.brightness,
          isStart: _trayTrafficActive,
          force: focus,
        );
      }
      if (system.isMacOS) {
        await _syncSpeedTitle(isStart: trayState.isStart);
      }
      if (_deferMenu) {
        _menuStale = true;
        return;
      }
      await _rebuildMenu(trayState, silent: silent);
      if (Platform.isLinux) {
        await _updateSystemTray(
          brightness: trayState.brightness,
          isStart: trayState.isStart,
          force: focus,
        );
      }
    } finally {
      _isUpdating = false;

      if (_pendingState != null) {
        final pending = _pendingState;
        final pendingFocus = _pendingFocus;
        final pendingSilent = _pendingSilent;
        _pendingState = null;
        _pendingFocus = false;
        _pendingSilent = false;
        await _doUpdate(
          trayState: pending!,
          focus: pendingFocus,
          silent: pendingSilent,
        );
      }
    }
  }

  /// MeowX：Windows 右键托盘图标时调用（manager/tray_manager.dart）：
  /// 菜单落后于当前状态（或还没建过）就先重建，再弹出；菜单关掉后才返回。
  Future<void> popUpMenu(TrayState trayState) async {
    _menuPopups++;
    try {
      if (_menuStale || _menuState != trayState) {
        try {
          await _rebuildMenu(trayState);
        } catch (e) {
          commonPrint.log('Failed to rebuild tray menu: $e');
        }
      }
      // ignore: deprecated_member_use
      await trayManager.popUpContextMenu(bringAppToFront: true);
    } finally {
      _menuPopups--;
    }
  }

  /// 按 [trayState] 从头建整棵菜单并下发给原生。
  Future<void> _rebuildMenu(TrayState trayState, {bool silent = false}) async {
    // 先清标记再建：建的过程中又来的更新（它会重新置位）不能被这一次的完成盖掉
    _menuStale = false;
    _menuState = trayState;
    try {
    List<MenuItem> menuItems = [];
    final showMenuItem = MenuItem(
      label: appLocalizations.show,
      onClick: (_) {
        window?.show();
      },
    );
    menuItems.add(showMenuItem);
    final startMenuItem = MenuItem.checkbox(
      label: trayState.isStart ? appLocalizations.stop : appLocalizations.start,
      onClick: (_) async {
        final appController = globalState.appController;
        await appController.updateStatus(!globalState.isStart);
        await appController.updateTray(false, false, true);
      },
      checked: false,
    );
    menuItems.add(startMenuItem);
    menuItems.add(MenuItem.separator());
    for (final mode in Mode.values) {
      menuItems.add(
        MenuItem.checkbox(
          label: Intl.message(mode.name),
          onClick: (_) {
            globalState.appController.changeMode(mode);
          },
          checked: mode == trayState.mode,
        ),
      );
    }
    menuItems.add(MenuItem.separator());
    // MeowX：菜单顺序按设计稿（design/ui-redesign/boards/WTray.dc.html）——
    // 显示 / 启停 → 模式 → 接管方式（TUN / 系统代理）→ 代理组 → 开机启动 / 终端代理命令 / 重启内核 → 更多 → 退出
    if (trayState.isStart) {
      menuItems.add(
        MenuItem.checkbox(
          label: appLocalizations.tun,
          onClick: (_) {
            globalState.appController.updateTun();
          },
          checked: trayState.tunEnable,
        ),
      );
      menuItems.add(
        MenuItem.checkbox(
          label: appLocalizations.systemProxy,
          onClick: (_) {
            globalState.appController.updateSystemProxy();
          },
          checked: trayState.systemProxy,
        ),
      );
      menuItems.add(MenuItem.separator());
    }
    if (trayState.trayEnhancement) {
      for (final group in trayState.groups) {
        List<MenuItem> subMenuItems = [];

        final isTestingThisGroup =
            delayTestCoordinator.isTestingGroup(group.name);

        subMenuItems.add(
          MenuItem(
            key: 'persistent-delay-test',
            label: isTestingThisGroup
                ? '⚡ ${appLocalizations.startTest}...'
                : '⚡ ${appLocalizations.startTest}',
            disabled: delayTestCoordinator.isTesting,
            onClick: (_) => _testGroupDelay(group),
          ),
        );

        subMenuItems.add(MenuItem.separator());

        final proxies = globalState.appController.getSortProxies(
          proxies: group.all,
          sortType: globalState.config.proxiesStyle.sortType,
          testUrl: group.testUrl,
        );
        for (final proxy in proxies) {
          final delay = globalState.appController.getTrayProxyDelay(
            proxyName: proxy.name,
            testUrl: group.testUrl,
          );

          subMenuItems.add(
            MenuItem.checkbox(
              key: 'proxy-item:${proxy.name}',
              label: proxy.name,
              sublabel: _formatProxySublabel(delay),
              checked: group.getCurrentSelectedName(trayState.selectedMap[group.name] ?? '') == proxy.name,
              onClick: (_) {
                final appController = globalState.appController;
                appController.updateCurrentSelectedMap(group.name, proxy.name);
                appController.changeProxy(
                  groupName: group.name,
                  proxyName: proxy.name,
                );
              },
            ),
          );
        }
        menuItems.add(
          MenuItem.submenu(
            label: group.name,
            submenu: Menu(items: subMenuItems),
          ),
        );
      }
      if (trayState.groups.isNotEmpty) {
        menuItems.add(MenuItem.separator());
      }
    }
    menuItems.addAll([
      MenuItem.checkbox(
        label: appLocalizations.autoLaunch,
        onClick: (_) async {
          globalState.appController.updateAutoLaunch();
        },
        checked: trayState.autoLaunch,
      ),
      _buildCopyEnvSubmenu(trayState.port),
      MenuItem(
        label: appLocalizations.restartCoreTitle,
        onClick: (_) async {
          final appController = globalState.appController;
          try {
            await appController.restartCore();
          } finally {
            await appController.syncDesktopRuntimeState(
              preferCurrentState: true,
            );
            await appController.updateTray();
          }
        },
      ),
    ]);

    final List<MenuItem> moreMenuItems = [
      MenuItem(
        label: appLocalizations.restartApp,
        onClick: (_) async {
          await Restart.restartApp();
        },
      ),
      if (!system.isAndroid)
        MenuItem.checkbox(
          label: appLocalizations.wakelock,
          onClick: (_) async {
            await _toggleWakelock(trayState.wakelockEnabled);
          },
          checked: trayState.wakelockEnabled,
        ),
    ];

    menuItems.add(
      MenuItem.submenu(
        label: appLocalizations.tools,   // 文案是「更多」
        submenu: Menu(items: moreMenuItems),
      ),
    );

    menuItems.add(MenuItem.separator());
    final exitMenuItem = MenuItem(
      label: appLocalizations.exit,
      onClick: (_) async {
        await globalState.appController.handleExit();
      },
    );
    menuItems.add(exitMenuItem);
    final menu = Menu(items: menuItems);
    await trayManager.setContextMenu(
      menu,
      keepMenuOpen: silent,
      brightness: trayState.brightness,
    );
    } catch (_) {
      _menuStale = true;
      rethrow;
    }
  }

  Future<void> updateSpeed(Traffic traffic) async {
    _lastTraffic = traffic;
    if (!system.isMacOS || !_traySpeedEnabled) {
      return;
    }
    await _setSpeedTitle(traffic);
  }

  Future<void> _syncSpeedTitle({required bool isStart}) async {
    if (!_traySpeedEnabled) {
      if (!_isSpeedTitleVisible) {
        return;
      }
      await trayManager.clearSpeedTitle();
      _isSpeedTitleVisible = false;
      _lastDisplayedUpload = null;
      _lastDisplayedDownload = null;
      _lastDisplayedActive = null;
      return;
    }

    if (!isStart) {
      _lastTraffic = Traffic();
    }
    await _setSpeedTitle(_lastTraffic);
  }

  Future<void> _setSpeedTitle(Traffic traffic) async {
    final upload = traffic.up.value;
    final download = traffic.down.value;
    if (_isSpeedTitleVisible &&
        _lastDisplayedUpload == upload &&
        _lastDisplayedDownload == download &&
        _lastDisplayedActive == _trayTrafficActive) {
      return;
    }
    await trayManager.setSpeedTitle(
      upload: upload,
      download: download,
      active: _trayTrafficActive,
    );
    _isSpeedTitleVisible = true;
    _lastDisplayedUpload = upload;
    _lastDisplayedDownload = download;
    _lastDisplayedActive = _trayTrafficActive;
  }

  MenuItem _buildCopyEnvSubmenu(int port) {
    final items = <MenuItem>[];

    final shells = <({String label, Future<void> Function() action})>[
      (label: 'PowerShell', action: () => _copyEnvPowerShell(port)),
      (label: 'CMD', action: () => _copyEnvCmd(port)),
      (label: 'Bash', action: () => _copyEnvBash(port)),
      (label: 'Fish', action: () => _copyEnvFish(port)),
    ];

    for (final shell in shells) {
      items.add(
        MenuItem(
          label: shell.label,
          onClick: (_) async {
            await shell.action();
          },
        ),
      );
    }

    return MenuItem.submenu(
      label: appLocalizations.copyEnvVar,
      submenu: Menu(items: items),
    );
  }

  Future<void> _copyEnvPowerShell(int port) async {
    final url = 'http://127.0.0.1:$port';
    final cmd = '\$env:http_proxy="$url"\n'
        '\$env:https_proxy="$url"\n'
        '\$env:all_proxy="$url"';
    await Clipboard.setData(ClipboardData(text: cmd));
  }

  Future<void> _copyEnvCmd(int port) async {
    final url = 'http://127.0.0.1:$port';
    final cmd = 'set http_proxy=$url\n'
        'set https_proxy=$url\n'
        'set all_proxy=$url';
    await Clipboard.setData(ClipboardData(text: cmd));
  }

  Future<void> _copyEnvBash(int port) async {
    final url = 'http://127.0.0.1:$port';
    final cmd = 'export http_proxy=$url\n'
        'export https_proxy=$url\n'
        'export all_proxy=$url';
    await Clipboard.setData(ClipboardData(text: cmd));
  }

  Future<void> _copyEnvFish(int port) async {
    final url = 'http://127.0.0.1:$port';
    final cmd = 'set -gx http_proxy $url\n'
        'set -gx https_proxy $url\n'
        'set -gx all_proxy $url';
    await Clipboard.setData(ClipboardData(text: cmd));
  }

  Future<void> _toggleWakelock(bool currentEnabled) async {
    try {
      if (currentEnabled) {
        try {
          await WakelockPlus.disable();
        } catch (e) {
          commonPrint.log('WakeLock disable OS error: $e');
        }
        globalState.appController.stopWakelockAutoRecovery();
      } else {
        try {
          await WakelockPlus.enable();
        } catch (e) {
          commonPrint.log('WakeLock enable OS error: $e');
        }
        globalState.appController.startWakelockAutoRecovery();
      }
      globalState.updateWakelockState(!currentEnabled);
      await globalState.appController.updateTray();
    } catch (e) {
      commonPrint.log('WakeLock toggle error: $e');
    }
  }

  String _formatProxySublabel(int? delay) {
    if (delay == null) {
      return '';
    } else if (delay == 0) {
      return system.isMacOS ? _loadingFrames[_loadingFrame] : '...';
    } else if (delay < 0) {
      return '×';
    } else {
      return '${delay}ms';
    }
  }

  void _startLoadingAnimation() {
    if (!system.isMacOS) {
      return;
    }
    _loadingTimer?.cancel();
    _loadingFrame = 0;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!delayTestCoordinator.isTesting) return;
      _scheduleLoadingUpdate();
    });
  }

  void _scheduleLoadingUpdate() {
    if (!delayTestCoordinator.isTesting || !system.isMacOS) return;
    _loadingTimer = Timer(const Duration(milliseconds: 300), () async {
      if (trayManager.isMenuOpen) {
        _loadingFrame = (_loadingFrame + 1) % _loadingFrames.length;
        await globalState.appController.updateTray(false, true);
      }
      _scheduleLoadingUpdate();
    });
  }

  void _stopLoadingAnimation() {
    _loadingTimer?.cancel();
    _loadingTimer = null;
    _loadingFrame = 0;
  }

  Future<void> _testGroupDelay(Group group) async {
    if (delayTestCoordinator.isTesting) return;

    final appController = globalState.appController;
    final testableProxies = group.all.where((p) {
      final name = p.name.toUpperCase();
      return name != 'REJECT' &&
          name != 'REJECT-DROP' &&
          name != 'PASS' &&
          p.type.toUpperCase() != 'REMATCH';
    }).toList();

    try {
      if (system.isMacOS) {
        _startLoadingAnimation();
      }
      await delayTest(
        testableProxies,
        testUrl: group.testUrl,
        groupName: group.name,
        onDelayUpdated: system.isMacOS
            ? () => appController.updateTray(false, true)
            : null,
      );
    } catch (e) {
      commonPrint.log('Delay test error: $e');
    } finally {
      if (system.isMacOS) {
        _stopLoadingAnimation();
      }
      await appController.updateTray(false, true);
    }
  }
}

final tray = Tray();
