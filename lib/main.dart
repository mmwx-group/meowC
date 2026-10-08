import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:bett_box/plugins/app.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lg;
import 'package:bett_box/plugins/clipboard_ext.dart';
import 'package:bett_box/plugins/tile.dart';
import 'package:bett_box/plugins/vpn.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

import 'application.dart';
import 'clash/core.dart';
import 'clash/lib.dart';
import 'common/common.dart';
import 'common/external_control.dart';
import 'common/network_matcher.dart';
import 'models/models.dart';
import 'pages/editor.dart';

ReceivePort? _serviceReceiverPort;
ReceivePort? _messageReceiverPort;

Future<void> main(List<String> args) async {
  globalState.isService = false;
  WidgetsFlutterBinding.ensureInitialized();

  if (system.isDesktop &&
      (args.contains('--exit') || args.contains('--restart'))) {
    final command = args.contains('--exit') ? 'exit' : 'restart';
    await _sendControlCommand(command);
    exit(0);
  }

  if (system.isMacOS) {
    final acquire = await singleInstanceLock.acquire();
    if (!acquire) {
      commonPrint.log(
        'SingleInstanceLock: another instance detected or lock failed, exiting',
      );
      await _sendControlCommand('show');
      await Future.delayed(const Duration(milliseconds: 100));
      exit(0);
    }
  }

  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;

  final version = await system.version;
  // MeowX：等核心通道就绪设了上限。Android 上 preload 等的是服务引擎把端口发回来，
  // 极慢的机器（或它压根没起来）不能让启动页一直挂着；界面先出来，核心调用自己会等通道（ClashLib.sendMessage）。
  await Future.wait([
    globalState.initApp(version),
    clashCore.preload().timeout(_preloadWaitLimit, onTimeout: () => false),
  ]);

  // MeowX：内置面板的解压（uiManager.initializeUI，安装 / 升级后首启才真的解压）不再挡首帧，
  // 挪到 AppController._initCore 里、核心初始化之前。

  await _runApp();
}

/// 首帧前最多等核心通道这么久：与 ClashLib._waitForIpc 的单次等待一致。
const _preloadWaitLimit = Duration(seconds: 2);

Future<void> _sendControlCommand(String command) async {
  for (int i = 0; i < 5; i++) {
    try {
      await ExternalControl.sendCommand(command);
      commonPrint.log('Sent $command command to running instance');
      return;
    } catch (e) {
      if (i == 4) {
        commonPrint.log('Failed to send $command command: $e');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}

Future<void> _runApp() async {
  if (system.isAndroid) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      commonPrint.log('Failed to set high refresh rate: $e');
    }
  }
  await android?.init();

  await window?.init();
  if (system.isWindows) {
    clipboardExt.init();
  }
  HttpOverrides.global = BettboxHttpOverrides();
  // MeowX：液态玻璃底栏的 shader 预热（不预热首帧会先闪一下磨砂）；wrap 让玻璃跟随 App 的深浅色而不是系统
  await lg.LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  runApp(
    lg.LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      // MeowX：底栏仍是 premium 液态玻璃，观感不变。库的自适应档位（按光栅耗时实测：预热 P75 ≥ 20ms、
      // 或运行中 P95 > 24ms 连续两个窗口就降一档）先只挂上来**采数据**：minQuality 与上限同为 premium = 永不降档，
      // 只把每次预热（冷启动、每次回前台各一次）实测的 P75 经 onDiagnostic 写进日志。
      // 没有直接放开到 standard：库量的是整帧光栅耗时（全局 FrameTiming），与底栏在不在画无关——一个本身就重的
      // 二级页（底栏根本没画）、或回前台那几秒恰好卡，都会把底栏压下去；而为了观感不来回变只能配 allowStepUp: false，
      // 一降就是整个进程。库自己记的中端机预热 P75 有 17–18ms，离 20ms 的线也近。
      // 等真机日志（低端 Mali 一台、中端一台）确认只有玻璃真跑不动时才触线，再把 minQuality 改成 standard
      // （降档后的底轨参数已备好，见 meow_root.dart 的 barGlass；届时 allowStepUp: false = 进程内只降不升）。
      // 只在 Android 的 Impeller 上接：Skia（Android 8–9）本来就走轻量路径，接了反而会让库换一套参数口径。
      adaptiveQuality: system.isAndroid && ImageFilter.isShaderFilterSupported,
      adaptiveConfig: const lg.GlassAdaptiveScopeConfig(
        minQuality: lg.GlassQuality.premium,
        allowStepUp: false,
        onDiagnostic: _logGlassQuality,
      ),
      child: ProviderScope(child: const Application()),
    ),
  );
  // MeowX：code_forge 的 Rust 库只有配置查看 / 编辑页用，不再挡首帧。进编辑页的入口都会先等它
  // （ensureEditorRuntime，只初始化一次）；这里在启动忙完后预热一次，正常使用时进编辑页不用现等。
  Timer(const Duration(seconds: 5), () => unawaited(ensureEditorRuntime()));
}

/// 液态玻璃档位的实测结果（预热 P75；放开降档后还有降档原因与当时的 P95）写进日志，方便拿真机数据校阈值。
void _logGlassQuality(lg.GlassAdaptiveDiagnostic d) => commonPrint.log('$d');

@pragma('vm:entry-point')
Future<void> _service(List<String> flags) async {
  globalState.isService = true;
  WidgetsFlutterBinding.ensureInitialized();
  await globalState.init();

  {
    final quickStart = flags.contains('quick');
    final bootStart = flags.contains('boot');
    final clashLibHandler = ClashLibHandler();
    final smartAutoStopLock = Lock();

    Future<void> checkSmartAutoStop() async {
      try {
        final vpnProps = globalState.config.vpnProps;
        if (!vpnProps.smartAutoStop) return;
        final networks = vpnProps.smartAutoStopNetworks;
        if (networks.isEmpty) return;

        await smartAutoStopLock.synchronized(() async {
          final isSmartStopped = await vpn?.isSmartStopped() ?? false;
          final candidateIps =
              await vpn?.getLocalIpAddresses() ?? const <String>[];
          final candidateGateways =
              await vpn?.getLocalGateways() ?? const <String>[];
          if (candidateIps.isEmpty && candidateGateways.isEmpty) return;

          final shouldStop =
              candidateIps.any(
                (ip) => NetworkMatcher.matchAny(ip, networks),
              ) ||
              candidateGateways.any(
                (gw) => NetworkMatcher.matchAnyGateway(gw, networks),
              );

          if (shouldStop && !isSmartStopped) {
            final isRunning = await vpn?.getStatus() ?? false;
            if (isRunning) {
              await vpn?.setSmartStopped(true);
              await vpn?.smartStop();
            }
          } else if (!shouldStop && isSmartStopped) {
            await vpn?.setSmartStopped(false);
            await vpn?.smartResume(clashLibHandler.getAndroidVpnOptions());
          }
        });
      } catch (e) {
        commonPrint.log('Smart auto stop check failed: $e');
      }
    }

    tile?.addListener(
      _TileListenerWithService(
        onStart: () async {
          await app.tip(appLocalizations.startVpn);
          await globalState.handleStart();
        },
        onStop: () async {
          await app.tip(appLocalizations.stopVpn);
          clashLibHandler.stopListener();
          await vpn?.stop();
        },
        onReconnectIpc: () {
          commonPrint.log(
            'Service: reconnectIpc requested, re-establishing IPC',
          );
          _handleMainIpc(clashLibHandler);
        },
      ),
    );

    vpn?.addListener(
      _VpnListenerWithService(
        onDnsChanged: (String dns) {
          clashLibHandler.updateDns(dns);
        },
        onNetworkChanged: checkSmartAutoStop,
      ),
    );

    if (!quickStart && !bootStart) {
      _handleMainIpc(clashLibHandler);
      return;
    }

    if (bootStart && !globalState.config.appSetting.autoRun) {
      commonPrint.log(
        'Silent boot detected, but autoRun is disabled. Staying idle.',
      );
      _handleMainIpc(clashLibHandler);
      return;
    }

    commonPrint.log('Executing ${bootStart ? "boot" : "quick"} start sequence');
    await ClashCore.initGeo();
    app.tip(appLocalizations.startVpn);
    final homeDirPath = await appPath.homeDirPath;
    final version = await system.version;
    final clashConfig = globalState.config.patchClashConfig.copyWith.tun(
      enable: false,
    );

    Future(() async {
      try {
        final params = await globalState.getSetupParams(
          pathConfig: clashConfig,
        );
        final profileId = globalState.config.currentProfileId;
        if (profileId == null) {
          return;
        }
        final res = await clashLibHandler.quickStart(
          InitParams(homeDir: homeDirPath, version: version),
          params,
          globalState.getCoreState(),
        );
        debugPrint(res);
        if (res.isNotEmpty) {
          commonPrint.log('QuickStart failed with error: $res');
          await vpn?.stop();
          return;
        }
        await vpn?.start(clashLibHandler.getAndroidVpnOptions());
        Future.delayed(const Duration(seconds: 2), checkSmartAutoStop);

        if (globalState.config.vpnProps.networkSpeedNotification) {
          final profile = globalState.config.profiles
              .where((e) => e.id == profileId)
              .firstOrNull;
          final profileName = profile?.label ?? 'MeowX';
          await vpn?.updateNotificationSpeed(profileName, '↑0B/s ↓0B/s');
        }

        if (globalState.config.appSetting.openLogs) {
          await clashLibHandler.invokeAction(
            '{"id": "quickStartLog", "method": "startLog"}',
          );
        } else {
          await clashLibHandler.invokeAction(
            '{"id": "quickStopLog", "method": "stopLog"}',
          );
        }

        clashLibHandler.startListener();
      } catch (e) {
        commonPrint.log('Fatal error during service background start: $e');
        await vpn?.stop();
      }
    });
  }
}

void _handleMainIpc(ClashLibHandler clashLibHandler) {
  final sendPort = IsolateNameServer.lookupPortByName(mainIsolate);
  if (sendPort == null) {
    commonPrint.log('Service: mainIsolate sendPort not found, IPC unavailable');
    return;
  }

  _serviceReceiverPort?.close();
  _messageReceiverPort?.close();

  _serviceReceiverPort = ReceivePort();
  _serviceReceiverPort!.listen((message) async {
    final res = await clashLibHandler.invokeAction(message);
    _safeSend(sendPort, res);
  });
  _safeSend(sendPort, _serviceReceiverPort!.sendPort);

  _messageReceiverPort = ReceivePort();
  clashLibHandler.attachMessagePort(_messageReceiverPort!.sendPort.nativePort);
  _messageReceiverPort!.listen((message) {
    _safeSend(sendPort, message);
  });

  clashLibHandler.startListener();
}

void _safeSend(SendPort sendPort, dynamic message) {
  try {
    sendPort.send(message);
  } catch (e) {
    commonPrint.log('Service: IPC send failed: $e');
    final retryPort = IsolateNameServer.lookupPortByName(mainIsolate);
    if (retryPort != null) {
      try {
        retryPort.send(message);
      } catch (_) {}
    }
  }
}

@immutable
class _TileListenerWithService with TileListener {
  final Function() _onStart;
  final Function() _onStop;
  final Function() _onReconnectIpc;

  const _TileListenerWithService({
    required Function() onStart,
    required Function() onStop,
    required Function() onReconnectIpc,
  }) : _onStart = onStart,
       _onStop = onStop,
       _onReconnectIpc = onReconnectIpc;

  @override
  void onStart() => _onStart();

  @override
  void onStop() => _onStop();

  @override
  void onReconnectIpc() => _onReconnectIpc();
}

@immutable
class _VpnListenerWithService with VpnListener {
  final Function(String dns) _onDnsChanged;
  final Function() _onNetworkChanged;

  const _VpnListenerWithService({
    required Function(String dns) onDnsChanged,
    required Function() onNetworkChanged,
  })  : _onDnsChanged = onDnsChanged,
        _onNetworkChanged = onNetworkChanged;

  @override
  void onDnsChanged(String dns) {
    super.onDnsChanged(dns);
    _onDnsChanged(dns);
  }

  @override
  void onNetworkChanged() {
    super.onNetworkChanged();
    _onNetworkChanged();
  }
}
