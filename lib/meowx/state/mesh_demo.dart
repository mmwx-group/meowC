import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mesh.dart';
import 'meow_settings.dart';

/// 仅 debug 生效的截图示例：`--dart-define=MEOWX_MESH_DEMO=true` 时假装登录了一台主控（`.invalid` 域名，什么都连不上）、
/// 喵窝开着，「组网」页填上示例的访问范围、设备、站点路由器与可用服务器，喵窝控制器不再问主控。
/// 订阅里的白名单节点（`_mmwx-mesh`）照真实路径处理（经喵窝拨号、画「喵窝」小标）。release 包里恒为 false。
const meshDemo = kDebugMode && bool.fromEnvironment('MEOWX_MESH_DEMO');

/// 填示例数据（MeowRoot 在偏好加载完之后调一次）。
void applyMeshDemo(WidgetRef ref) {
  if (!meshDemo) return;
  ref
      .read(meowSettingProvider.notifier)
      .updateState(
        (s) => s.copyWith(
          account: s.account.copyWith(host: 'https://panel.demo.invalid', token: 'demo-token', nickname: '示例账号'),
          tailscaleNodes: false,
          mesh: s.mesh.copyWith(
            enabled: true,
            controlUrl: 'https://mesh.demo.invalid',
            magicDns: 'meowx.internal',
            hostname: 'pixel-9',
            nodeId: 7,
            panelReason: '',
          ),
        ),
      );
  final now = DateTime.now();
  ref
      .read(meshProvider.notifier)
      .showDemo(
        MeshState(
          availability: MeshAvailability.available,
          magicDns: 'meowx.internal',
          accessScope: 'sites',
          deviceLimit: 5,
          devices: [
            const MeshDevice(id: 7, name: 'pixel-9', ipv4: '100.64.0.7', online: true),
            const MeshDevice(id: 3, name: 'openwrt', ipv4: '100.64.0.3', online: true, routes: ['192.168.1.0/24']),
            MeshDevice(id: 5, name: 'macbook', ipv4: '100.64.0.5', lastSeen: now.subtract(const Duration(hours: 2))),
          ],
          sites: const [MeshSite(id: 2, original: '192.168.1.0/24', advertised: '192.168.1.0/24')],
          sharedDevices: const [
            MeshDevice(id: 31, name: 'boss-router', online: true, username: 'boss', routes: ['192.168.9.0/24', '10.9.0.0/24']),
          ],
          servers: const [
            MeshServer(name: '香港 01', meshIp: '100.64.0.21', serverId: 1),
            MeshServer(name: '东京 IEPL', meshIp: '100.64.0.22', serverId: 2),
          ],
          devicesComplete: true,
          devicesAt: now,
          stateNodeId: 7,
          stateNodeIdAt: now,
        ),
      );
}
