import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/providers/config.dart';
import 'package:bett_box/providers/state.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/proxies/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ClashManager extends ConsumerStatefulWidget {
  final Widget child;

  const ClashManager({super.key, required this.child});

  @override
  ConsumerState<ClashManager> createState() => _ClashContainerState();
}

class _ClashContainerState extends ConsumerState<ClashManager>
    with AppMessageListener {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    clashMessage.addListener(this);
    ref.listenManual(needSetupProvider, (prev, next) {
      if (prev != next) {
        final profileChanged = prev?.a != next.a;
        unawaited(
          globalState.appController
              .handleChangeProfile(
                hardRestart: system.isDesktop && profileChanged,
              )
              .catchError((Object error, StackTrace stackTrace) {
                commonPrint.log('Profile change failed: $error');
              }),
        );
      }
    });
    ref.listenManual(coreStateProvider, (prev, next) async {
      if (prev != next) {
        await clashCore.setState(next);
      }
    });
    ref.listenManual(updateParamsProvider, (prev, next) {
      if (prev != next) {
        globalState.appController.updateClashConfigDebounce();
      }
    });

    ref.listenManual(appSettingProvider.select((state) => state.openLogs), (
      prev,
      next,
    ) {
      if (next) {
        clashCore.startLog();
      } else {
        clashCore.stopLog();
      }
    });
  }

  @override
  Future<void> dispose() async {
    clashMessage.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onDelay(Delay delay) async {
    super.onDelay(delay);
    final appController = globalState.appController;
    appController.setDelay(delay);
    // MeowX：界面发起的测速（测全部 / 测本组 / 点延迟胶囊）还在跑时不排这一趟——测速收尾自己会拉代理组
    // （views/proxies/common.dart），否则测完约 5.6 秒后还要再全量拉一遍。核心先推这条消息再回测速结果，所以此时请求还挂着。
    if (hasPendingDelayTest) return;
    // MeowX：Android 退到后台后没有界面在看代理组，健康检查的结果只记延迟；欠的这一趟回前台补
    // （桌面不省：窗口收在托盘时托盘菜单里的当前节点还要跟着变）。
    if (system.isAndroid && globalState.backgroundMode.value) {
      appController.deferGroupsUpdate();
      return;
    }
    debouncer.call(FunctionTag.updateDelay, () async {
      appController.updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
  }

  @override
  void onLog(Log log) {
    ref.read(logsProvider.notifier).addLog(log);
    if (log.logLevel == LogLevel.error) {
      globalState.showNotifier(log.payload);
    }
    super.onLog(log);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) async {
    ref.read(requestsProvider.notifier).addRequest(trackerInfo);
    super.onRequest(trackerInfo);
  }

  @override
  Future<void> onLoaded(String providerName) async {
    ref
        .read(providersProvider.notifier)
        .setProvider(await clashCore.getExternalProvider(providerName));
    globalState.appController.updateGroupsDebounce();
    super.onLoaded(providerName);
  }
}
