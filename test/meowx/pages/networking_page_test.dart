import 'package:bett_box/meowx/config/mesh_config.dart';
import 'package:bett_box/meowx/pages/dashboard/mesh_card.dart';
import 'package:bett_box/meowx/pages/me/me_kit.dart';
import 'package:bett_box/meowx/pages/settings/networking_page.dart';
import 'package:bett_box/meowx/state/mesh.dart';
import 'package:bett_box/meowx/state/meow_settings.dart';
import 'package:bett_box/meowx/state/status.dart';
import 'package:bett_box/meowx/state/tailscale_status.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Meow extends MeowSetting {
  _Meow(this.initial);
  final MeowSettings initial;

  @override
  MeowSettings build() => initial;

  @override
  void onUpdate(MeowSettings value) {}
}

class _Patch extends PatchClashConfig {
  @override
  ClashConfig build() => const ClashConfig();

  @override
  void onUpdate(ClashConfig value) {}
}

/// 不碰主控 / 内核 / 文件的替身：状态给定，切换只记下来。
class _FakeMesh extends MeshController {
  _FakeMesh(this.initial, this.calls);
  final MeshState initial;
  final List<NetworkingMode> calls;

  @override
  MeshState build() => initial;

  @override
  Future<void> tick({Duration devicesEvery = const Duration(seconds: 30)}) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> setMode(NetworkingMode mode) async {
    calls.add(mode);
    return true;
  }

  /// 只做规范化与存设置（真的那份开着时还要重新应用配置）
  @override
  Future<String?> setCustomHostname(String input) async {
    final parsed = parseMeshCustomHostname(input);
    if (parsed.error != null) return parsed.error;
    ref.read(meowSettingProvider.notifier).updateState((s) => s.copyWith(mesh: s.mesh.copyWith(customHostname: parsed.name)));
    return null;
  }
}

const _admin = MeowAccount(host: 'https://panel.example.com', token: 't');

const _devices = [
  MeshDevice(id: 7, name: 'pixel-8', ipv4: '100.64.0.7', online: true),
  MeshDevice(id: 3, name: 'openwrt', ipv4: '100.64.0.3', online: true, routes: ['192.168.1.0/24']),
  MeshDevice(id: 5, name: 'macbook', ipv4: '100.64.0.5'),
];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  MeowSettings meow = const MeowSettings(account: _admin),
  MeshState mesh = const MeshState(availability: MeshAvailability.available),
  bool running = false,
  List<NetworkingMode>? calls,
  Size size = const Size(412, 892),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isRunningProvider.overrideWithValue(running),
        meowSettingProvider.overrideWith(() => _Meow(meow)),
        patchClashConfigProvider.overrideWith(_Patch.new),
        meshProvider.overrideWith(() => _FakeMesh(mesh, calls ?? [])),
        meshAutoHostnameProvider.overrideWith((ref) async => 'sm-s9180'),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    // 订阅组网节点的状态：家里已连接、能直连到 nas
    debugFetchTailscaleStatus = (name) async => (
      status: const TsStatus(
        state: 'Running',
        self: TsPeer(id: 1, name: 'pixel', addresses: ['100.101.1.2'], online: true),
        peers: [TsPeer(id: 2, name: 'nas', addresses: ['100.101.1.3'], online: true, active: true, relay: 'tok')],
      ),
      error: null,
    );
  });
  tearDown(() {
    meshRuntime.subscriptionNodes.value = const [];
    debugFetchTailscaleStatus = null;
  });

  testWidgets('组网页：管理员看得到喵窝；订阅里没有组网节点时 Tailscale 画灰、点了说原因', (tester) async {
    final calls = <NetworkingMode>[];
    await _pump(tester, const NetworkingPage(), calls: calls);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('喵窝'), findsOneWidget);
    expect(find.text('Tailscale'), findsOneWidget);
    await tester.tap(find.text('Tailscale'));
    await tester.pumpAndSettle();
    expect(find.text('当前订阅里没有 Tailscale 组网节点'), findsOneWidget);
    expect(calls, isEmpty);
    // 代理没在跑：不用确认，直接切
    await tester.tap(find.text('喵窝'));
    await tester.pumpAndSettle();
    expect(calls, [NetworkingMode.mesh]);
  });

  testWidgets('组网页：不是管理员时没有喵窝那一项', (tester) async {
    await _pump(tester, const NetworkingPage(), mesh: const MeshState(availability: MeshAvailability.notAdmin));
    expect(find.text('喵窝'), findsNothing);
    expect(find.text('Tailscale'), findsOneWidget);
  });

  testWidgets('组网页：代理在跑时切换先确认，取消就不切', (tester) async {
    meshRuntime.subscriptionNodes.value = const ['家里'];
    final calls = <NetworkingMode>[];
    await _pump(tester, const NetworkingPage(), running: true, calls: calls);
    // 订阅里有组网节点、开关缺省开 → 现在是 Tailscale：列出节点与内核给的状态、各设备直连还是中继
    await tester.pump();
    expect(find.text('家里'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('100.101.1.2'), findsOneWidget);
    expect(find.text('中继 · tok'), findsOneWidget);
    await tester.tap(find.text('喵窝'));
    await tester.pumpAndSettle();
    expect(find.text('切换到「喵窝」'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.text('喵窝'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(calls, [NetworkingMode.mesh]);
  });

  testWidgets('组网页：喵窝开着时显示状态、本机地址、我的设备、我的站点与退出', (tester) async {
    await _pump(
      tester,
      const NetworkingPage(),
      running: true,
      meow: const MeowSettings(
        account: _admin,
        tailscaleNodes: false,
        mesh: MeowMesh(enabled: true, controlUrl: 'https://x', hostname: 'pixel-8', nodeId: 7, panelReason: ''),
      ),
      mesh: MeshState(
        availability: MeshAvailability.available,
        devices: _devices,
        sites: const [
          MeshSite(id: 2, original: '192.168.1.0/24', advertised: '192.168.1.0/24'),
          MeshSite(id: 4, original: '192.168.1.0/24', advertised: '10.233.0.0/24', mapped: true),
        ],
        devicesComplete: true,
        devicesAt: DateTime.now(),
        stateNodeId: 7,
        stateNodeIdAt: DateTime.now(),
        engine: const TsStatus(
          state: 'Running',
          self: TsPeer(id: 7, name: 'pixel-8', addresses: ['100.64.0.7'], online: true),
          peers: [TsPeer(id: 3, name: 'openwrt', addresses: ['100.64.0.3'], online: true, curAddr: '203.0.113.7:41641', relay: 'meowx-1')],
        ),
      ),
    );
    expect(find.text('直连'), findsOneWidget);   // openwrt：内核说打通了直连
    expect(find.text('已连接 · 1 台在线'), findsOneWidget);
    expect(find.widgetWithText(MeRow, '本机地址'), findsOneWidget);
    expect(find.text('100.64.0.7'), findsNWidgets(2));   // 本机地址一行 + 设备列表里本机的副标题
    expect(find.text('pixel-8（本机）'), findsOneWidget);
    expect(find.text('openwrt'), findsOneWidget);
    expect(find.text('192.168.1.0/24 → 10.233.0.0/24'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('退出喵窝'), 200);
    expect(find.text('退出喵窝'), findsOneWidget);
  });

  testWidgets('组网页：加入了管理员的喵窝时多一行「已加入」与「同网络的设备」（只读、点按复制地址、写主人）', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _pump(
      tester,
      const NetworkingPage(),
      size: const Size(412, 2000),
      running: true,
      meow: const MeowSettings(
        account: _admin,
        tailscaleNodes: false,
        mesh: MeowMesh(enabled: true, controlUrl: 'https://x', hostname: 'pixel-8', nodeId: 7, panelReason: ''),
      ),
      mesh: MeshState(
        availability: MeshAvailability.available,
        joinedAdmin: 'boss',
        devices: _devices,
        sharedDevices: [
          const MeshDevice(id: 21, name: 'boss-nas', ipv4: '100.64.0.21', online: true, username: 'boss', routes: ['192.168.9.0/24']),
          MeshDevice(
            id: 22,
            name: 'carol-mac',
            ipv4: '100.64.0.22',
            lastSeen: DateTime.now().subtract(const Duration(hours: 3)),
            username: 'carol',
          ),
        ],
        devicesComplete: true,
        devicesAt: DateTime.now(),
        stateNodeId: 7,
        stateNodeIdAt: DateTime.now(),
      ),
    );
    expect(find.text('已加入 boss 的喵窝'), findsOneWidget);
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('同网络的设备'), findsOneWidget);
    // 在线台数只算我的设备（openwrt），别人的 boss-nas 不算
    expect(find.text('已连接 · 1 台在线'), findsOneWidget);
    expect(find.text('boss-nas'), findsOneWidget);
    expect(find.text('100.64.0.21 · 192.168.9.0/24 · 属于 boss'), findsOneWidget);
    expect(find.text('100.64.0.22 · 属于 carol'), findsOneWidget);
    expect(find.text('离线 · 3 小时前'), findsOneWidget);
    // 同网络设备的行没有任何操作入口（没有箭头 / 按钮 / 开关），点按只复制地址
    final row = find.ancestor(of: find.text('boss-nas'), matching: find.byType(MeRow));
    expect(tester.widget<MeRow>(row).trailing, isNull);
    expect(tester.widget<MeRow>(row).chevron, isFalse);
    for (final type in [IconButton, TextButton, FilledButton, PopupMenuButton, Switch]) {
      expect(find.descendant(of: row, matching: find.byType(type)), findsNothing);
    }
    await tester.tap(find.text('boss-nas'));
    await tester.pump();
    expect(copied, ['100.64.0.21']);
    expect(find.text('删除'), findsNothing);
    expect(find.text('改名'), findsNothing);
  });

  testWidgets('组网页（宽屏）：同样有「已加入」与「同网络的设备」', (tester) async {
    await _pump(
      tester,
      const NetworkingPage(),
      size: const Size(1280, 1400),
      running: true,
      meow: const MeowSettings(
        account: _admin,
        tailscaleNodes: false,
        mesh: MeowMesh(enabled: true, controlUrl: 'https://x', hostname: 'pixel-8', nodeId: 7, panelReason: ''),
      ),
      mesh: MeshState(
        availability: MeshAvailability.available,
        joinedAdmin: 'boss',
        devices: _devices,
        sharedDevices: const [MeshDevice(id: 21, name: 'boss-nas', ipv4: '100.64.0.21', online: true, username: 'boss')],
        devicesComplete: true,
        devicesAt: DateTime.now(),
        stateNodeId: 7,
      ),
    );
    expect(find.text('已加入 boss 的喵窝'), findsOneWidget);
    expect(find.text('同网络的设备'), findsOneWidget);
    expect(find.text('100.64.0.21 · 属于 boss'), findsOneWidget);
  });

  testWidgets('组网页：独立喵窝（老主控）不显示「已加入」与「同网络的设备」', (tester) async {
    await _pump(
      tester,
      const NetworkingPage(),
      meow: const MeowSettings(
        account: _admin,
        tailscaleNodes: false,
        mesh: MeowMesh(enabled: true, controlUrl: 'https://x', hostname: 'pixel-8', nodeId: 7, panelReason: ''),
      ),
      mesh: MeshState(
        availability: MeshAvailability.available,
        devices: _devices,
        devicesComplete: true,
        devicesAt: DateTime.now(),
        stateNodeId: 7,
      ),
    );
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.textContaining('已加入'), findsNothing);
    expect(find.text('同网络的设备'), findsNothing);
  });

  testWidgets('组网页：没开喵窝也能先改设备名——显示自动名、编辑时预览 DNS 名、不合法不保存、留空恢复自动名', (tester) async {
    await _pump(tester, const NetworkingPage(), mesh: const MeshState(availability: MeshAvailability.available, magicDns: 'home.example'));
    await tester.pump();
    expect(find.text('设备名'), findsOneWidget);
    expect(find.text('sm-s9180'), findsOneWidget);
    expect(find.text('自动（本机型号 / 计算机名）'), findsOneWidget);
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(find.text('将显示为 sm-s9180.home.example'), findsOneWidget);   // 留空 = 自动名
    await tester.enterText(find.byType(TextField), 'Living Room');
    await tester.pump();
    expect(find.text('将显示为 living-room.home.example'), findsOneWidget);
    expect(find.textContaining('主控会自动在后面加 -1、-2'), findsOneWidget);
    // 规范化后为空：预览换成错误，保存也不收
    await tester.enterText(find.byType(TextField), '客厅');
    await tester.pump();
    expect(find.text('设备名只能用英文字母、数字和横线'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    // 合法的：存下规范化后的名字，回到只读一行
    await tester.enterText(find.byType(TextField), 'Living Room');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('living-room'), findsOneWidget);
    expect(find.text('自动（本机型号 / 计算机名）'), findsNothing);
    // 取消不改；留空保存 = 恢复自动名
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'living-room');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('living-room'), findsOneWidget);
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('sm-s9180'), findsOneWidget);
  });

  testWidgets('组网页：不是管理员（喵窝不可用）时没有设备名一行', (tester) async {
    await _pump(tester, const NetworkingPage(), mesh: const MeshState(availability: MeshAvailability.notAdmin));
    expect(find.text('设备名'), findsNothing);
  });

  testWidgets('组网页（宽屏）：喵窝开着时设备名在喵窝卡片里，后缀用设置里的 MagicDNS', (tester) async {
    await _pump(
      tester,
      const NetworkingPage(),
      size: const Size(1280, 800),
      meow: const MeowSettings(
        account: _admin,
        tailscaleNodes: false,
        mesh: MeowMesh(enabled: true, controlUrl: 'https://x', hostname: 'nas', customHostname: 'nas', magicDns: 'lan.example', panelReason: ''),
      ),
    );
    expect(find.text('nas'), findsOneWidget);
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(find.text('将显示为 nas.lan.example'), findsOneWidget);
  });

  testWidgets('首页喵窝卡：开关、状态、本机地址与在线几台', (tester) async {
    await _pump(
      tester,
      const HomeMeshCard(),
      running: true,
      meow: const MeowSettings(
        account: _admin,
        mesh: MeowMesh(enabled: true, controlUrl: 'https://x', nodeId: 7, panelReason: ''),
      ),
      mesh: const MeshState(availability: MeshAvailability.available, devices: _devices, stateNodeId: 7),
    );
    expect(find.text('喵窝'), findsOneWidget);
    expect(find.text('已连接 · 1 台在线'), findsOneWidget);
    expect(find.text('100.64.0.7'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('首页喵窝卡：同网络别人的设备不算进在线台数', (tester) async {
    await _pump(
      tester,
      const HomeMeshCard(),
      running: true,
      meow: const MeowSettings(
        account: _admin,
        mesh: MeowMesh(enabled: true, controlUrl: 'https://x', nodeId: 7, panelReason: ''),
      ),
      mesh: const MeshState(
        availability: MeshAvailability.available,
        joinedAdmin: 'boss',
        devices: _devices,
        sharedDevices: [
          MeshDevice(id: 21, name: 'boss-nas', ipv4: '100.64.0.21', online: true, username: 'boss'),
          MeshDevice(id: 22, name: 'boss-pc', ipv4: '100.64.0.22', online: true, username: 'boss'),
        ],
        stateNodeId: 7,
      ),
    );
    expect(find.text('已连接 · 1 台在线'), findsOneWidget);
    expect(find.text('boss-nas'), findsNothing);
  });

  testWidgets('首页喵窝卡：关着时打开 = 切到喵窝', (tester) async {
    final calls = <NetworkingMode>[];
    await _pump(tester, const HomeMeshCard(), calls: calls);
    expect(find.text('关闭'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(calls, [NetworkingMode.mesh]);
  });
}
