import 'package:bett_box/common/tray.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows 上托盘菜单改成「平时只记脏，右键弹出前才重建」。本机跑不了 Windows，
/// 用 debugLazyMenu 顶替平台判断，原生侧用 tray_manager 通道的替身记录调用顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tray_manager');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  TrayState state({bool isStart = false}) => TrayState(
        mode: Mode.rule,
        port: 7890,
        autoLaunch: false,
        systemProxy: true,
        tunEnable: false,
        isStart: isStart,
        locale: 'en',
        brightness: Brightness.light,
        groups: const [],
        selectedMap: const {},
        trayEnhancement: false,
      );

  /// 模拟原生侧发来的事件（菜单打开 / 关闭）。
  Future<void> native(String method) => messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) {},
      );

  /// 等过静默更新的 50ms 防抖。
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 120));

  /// 只看菜单相关的调用（Linux 上跑测试时更新流程末尾还会多一次 setIcon，与本文件要验的无关）。
  List<String> names() => [
        for (final c in calls)
          if (c.method == 'setContextMenu' || c.method == 'popUpContextMenu') c.method,
      ];

  setUpAll(() => AppLocalizations.load(const Locale('en')));

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('状态变化只记脏，不下发菜单；右键弹出前才重建一次', () async {
    final tray = Tray()..debugLazyMenu = true;
    addTearDown(tray.dispose);

    await tray.update(trayState: state(), silent: true);
    await settle();
    await tray.update(trayState: state(isStart: true), silent: true);
    await settle();
    expect(names(), isEmpty, reason: '没人打开菜单时不该碰原生菜单');

    await tray.popUpMenu(state(isStart: true));
    expect(names(), ['setContextMenu', 'popUpContextMenu'], reason: '先建好再弹');
    // 菜单是按弹出那一刻的状态建的：已连接时第二项是「停止」
    final built = calls.firstWhere((c) => c.method == 'setContextMenu');
    final items = ((built.arguments as Map)['menu'] as Map)['items'] as List;
    expect((items[1] as Map)['label'], AppLocalizations.current.stop);
  });

  test('状态没变再弹不重建；状态变了 / 期间有过被推迟的更新才重建', () async {
    final tray = Tray()..debugLazyMenu = true;
    addTearDown(tray.dispose);

    await tray.popUpMenu(state());
    expect(names(), ['setContextMenu', 'popUpContextMenu'], reason: '还没建过，第一次必建');

    calls.clear();
    await tray.popUpMenu(state());
    expect(names(), ['popUpContextMenu']);

    calls.clear();
    await tray.popUpMenu(state(isStart: true));
    expect(names(), ['setContextMenu', 'popUpContextMenu']);

    // 同一份状态下的静默更新（测速起止：延迟变了、状态没变）也要让下次弹出重建
    calls.clear();
    await tray.update(trayState: state(isStart: true), silent: true);
    await settle();
    expect(names(), isEmpty);
    await tray.popUpMenu(state(isStart: true));
    expect(names(), ['setContextMenu', 'popUpContextMenu']);
  });

  test('菜单正开着时照旧立即更新（原地改标签，不关菜单）', () async {
    final tray = Tray()..debugLazyMenu = true;
    addTearDown(tray.dispose);
    await tray.popUpMenu(state());
    calls.clear();

    await native('onMenuOpen');
    await tray.update(trayState: state(isStart: true), silent: true);
    await settle();
    expect(names(), ['setContextMenu']);
    final update = calls.firstWhere((c) => c.method == 'setContextMenu');
    expect((update.arguments as Map)['keepMenuOpen'], isTrue);

    await native('onMenuClose');
    calls.clear();
    await tray.update(trayState: state(), silent: true);
    await settle();
    expect(names(), isEmpty, reason: '菜单关了以后又回到只记脏');
  });
}
