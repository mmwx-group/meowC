import 'package:bett_box/meowx/panel/client.dart';
import 'package:bett_box/meowx/panel/mesh.dart';
import 'package:bett_box/meowx/state/mesh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mesh/status 的 joined_admin', () {
    test('加入了管理员的喵窝：取用户名', () {
      final s = MeshPanelStatus.parse({'available': true, 'control_url': 'https://c', 'joined_admin': 'admin'});
      expect(s.available, isTrue);
      expect(s.joinedAdmin, 'admin');
    });

    test('老主控没有这个字段 / 空 / null = 独立喵窝', () {
      expect(MeshPanelStatus.parse({'available': true}).joinedAdmin, '');
      expect(MeshPanelStatus.parse({'available': true, 'joined_admin': ''}).joinedAdmin, '');
      expect(MeshPanelStatus.parse({'available': true, 'joined_admin': null}).joinedAdmin, '');
      expect(MeshPanelStatus.parse({'available': true, 'joined_admin': '  '}).joinedAdmin, '');
    });
  });

  group('mesh/devices 的 shared_devices', () {
    final mine = {'id': 7, 'name': 'pixel-8', 'ipv4': '100.64.0.7', 'online': true, 'user_id': 2};
    final shared = {
      'id': 9,
      'name': 'nas',
      'dns_name': 'nas.mesh.example',
      'user_id': 1,
      'username': 'admin',
      'ipv4': '100.64.0.9',
      'online': false,
      'last_seen': '2026-11-09T10:00:00Z',
      'created_at': '2026-11-01T10:00:00Z',
      'routes': ['192.168.5.0/24'],
      'pending_routes': <String>[],
    };

    test('同网络里别人的设备单独成列，带主人；不混进我的设备', () {
      final l = MeshDeviceList.parse({
        'devices': [mine],
        'sites': const [],
        'shared_devices': [shared],
      });
      expect(l.devices.map((d) => d.id), [7]);
      expect(l.devices.single.username, '');
      final d = l.sharedDevices.single;
      expect(d.id, 9);
      expect(d.name, 'nas');
      expect(d.username, 'admin');
      expect(d.ipv4, '100.64.0.9');
      expect(d.online, isFalse);
      expect(d.lastSeen, DateTime.utc(2026, 11, 9, 10));
      expect(d.routes, ['192.168.5.0/24']);
    });

    test('独立喵窝 / 老主控没有这个字段、null、不是列表、空列表 = 空；坏条目跳过', () {
      for (final v in [null, 'x', <Object>[]]) {
        final r = <String, dynamic>{
          'devices': [mine],
        };
        if (v != null) r['shared_devices'] = v;
        expect(MeshDeviceList.parse(r).sharedDevices, isEmpty);
      }
      expect(
        MeshDeviceList.parse({
          'devices': [mine],
          'shared_devices': null,
        }).sharedDevices,
        isEmpty,
      );
      final l = MeshDeviceList.parse({
        'devices': [mine],
        'shared_devices': [
          'bad',
          {'name': '没有编号'},
          {'id': 10, 'name': 'router'},
        ],
      });
      expect(l.sharedDevices.map((d) => (d.id, d.username)), [(10, '')]);
    });

    test('在线台数只算我的设备，同网络别人的设备不算', () {
      final l = MeshDeviceList.parse({
        'devices': [
          mine,
          {'id': 3, 'name': 'openwrt', 'online': true},
        ],
        'shared_devices': [
          {...shared, 'online': true},
          {...shared, 'id': 11, 'online': true},
        ],
      });
      final s = MeshState(devices: l.devices, sharedDevices: l.sharedDevices, stateNodeId: 7);
      expect(s.onlineOthers(null), 1);
    });
  });

  group('mesh/status 的访问范围 / 设备上限 / 可用服务器（规格 A1 / A3 / A6）', () {
    test('三种访问范围各一行文字；旧主控没有 / 认不出 = 不显示', () {
      for (final (v, text) in [
        ('servers', '访问范围：仅服务器'),
        ('sites', '访问范围：服务器 + 管理员站点'),
        ('full', '访问范围：完全互通'),
        ('FULL', '访问范围：完全互通'),
      ]) {
        final s = MeshPanelStatus.parse({'available': true, 'access_scope': v});
        expect(meshAccessScopeText(s.accessScope), text, reason: v);
      }
      expect(MeshPanelStatus.parse({'available': true}).accessScope, '');
      expect(meshAccessScopeText(MeshPanelStatus.parse({'available': true}).accessScope), isNull);
      expect(meshAccessScopeText(MeshPanelStatus.parse({'available': true, 'access_scope': 'other'}).accessScope), isNull);
      expect(meshAccessScopeText(MeshPanelStatus.parse({'available': true, 'access_scope': null}).accessScope), isNull);
    });

    test('设备上限：0 = 不限，没有字段 = null（不显示）', () {
      expect(MeshPanelStatus.parse({'available': true, 'device_limit': 0}).deviceLimit, 0);
      expect(meshDeviceLimitText(0), '不限');
      expect(MeshPanelStatus.parse({'available': true, 'device_limit': 5}).deviceLimit, 5);
      expect(MeshPanelStatus.parse({'available': true, 'device_limit': '3'}).deviceLimit, 3);
      expect(meshDeviceLimitText(5), '5 台');
      expect(MeshPanelStatus.parse({'available': true}).deviceLimit, isNull);
      // 不在名单里也是 200，照样读得出来
      final no = MeshPanelStatus.parse({'available': false, 'reason': 'not_admin', 'device_limit': 0});
      expect(no.reason, 'not_admin');
      expect(no.deviceLimit, 0);
    });

    test('servers：有就列，宽松解析、缺名称或地址的条目丢掉；没有 = 空', () {
      expect(MeshPanelStatus.parse({'available': true}).servers, isEmpty);
      expect(MeshPanelStatus.parse({'available': true, 'servers': null}).servers, isEmpty);
      expect(MeshPanelStatus.parse({'available': true, 'servers': 'x'}).servers, isEmpty);
      final s = MeshPanelStatus.parse({
        'available': true,
        'servers': [
          {'name': '香港 01', 'mesh_ip': '100.64.0.21', 'server_id': 12},
          {'name': '东京', 'mesh_ip': '100.64.0.22'},
          {'name': '没有地址'},
          {'mesh_ip': '100.64.0.23'},
          {'name': ' ', 'mesh_ip': '100.64.0.24'},
          'bad',
        ],
      });
      expect(s.servers.map((e) => (e.name, e.meshIp, e.serverId)), [('香港 01', '100.64.0.21', 12), ('东京', '100.64.0.22', null)]);
    });
  });

  group('共享设备：null 网段与站点路由器（规格 A2）', () {
    test('routes / pending_routes 为 null 或缺失 = 空列表', () {
      final l = MeshDeviceList.parse({
        'devices': const [],
        'sites': const [],
        'shared_devices': [
          {'id': 1, 'name': 'a', 'ipv4': '100.64.0.1', 'routes': null, 'pending_routes': null},
          {'id': 2, 'name': 'b', 'ipv4': '100.64.0.2'},
        ],
      });
      for (final d in l.sharedDevices) {
        expect(d.routes, isEmpty);
        expect(d.pendingRoutes, isEmpty);
        expect(d.isSiteRouter, isFalse);
      }
    });

    test('sites 范围下的站点路由器：没有地址与 DNS 名、只有网段', () {
      final l = MeshDeviceList.parse({
        'devices': const [],
        'shared_devices': [
          {'id': 5, 'name': 'openwrt', 'username': 'admin', 'ipv4': '', 'dns_name': '', 'routes': ['192.168.1.0/24', '10.0.0.0/24']},
        ],
      });
      final d = l.sharedDevices.single;
      expect(d.isSiteRouter, isTrue);
      expect(d.routes, ['192.168.1.0/24', '10.0.0.0/24']);
      expect(d.username, 'admin');
      // full 范围下的普通共享设备有地址：不是站点路由器
      final full = MeshDevice.parse({'id': 6, 'name': 'nas', 'ipv4': '100.64.0.6', 'dns_name': 'nas.x', 'routes': ['192.168.5.0/24']})!;
      expect(full.isSiteRouter, isFalse);
      expect(full.dnsName, 'nas.x');
    });
  });

  group('喵窝管理接口的错误码（规格 A4）', () {
    test('按状态码分处理方式', () {
      expect(meshErrorAction(const MeshApiException(401, 'unauthorized')), MeshErrorAction.relogin);
      expect(meshErrorAction(const MeshApiException(403, 'forbidden')), MeshErrorAction.recheck);
      expect(meshErrorAction(const MeshApiException(409, 'conflict')), MeshErrorAction.conflict);
      expect(meshErrorAction(const MeshApiException(429, 'slow down')), MeshErrorAction.backoff);
      expect(meshErrorAction(const MeshApiException(503, 'starting')), MeshErrorAction.backoff);
      expect(meshErrorAction(const MeshApiException(502, 'headscale')), MeshErrorAction.unreachable);
      expect(meshErrorAction(const MeshApiException(404, 'not found')), MeshErrorAction.other);
      expect(meshErrorAction(const PanelException('无法连接主控')), MeshErrorAction.other);
    });

    test('给人看的话：409 按重查后的原因分主控关了 / 设备数到上限', () {
      const conflict = MeshApiException(409, 'device limit reached');
      expect(meshErrorText(conflict, reason: 'disabled'), '主控已关闭喵窝');
      expect(meshErrorText(conflict, reason: '', deviceLimit: 3), '设备数已达上限（3 台）');
      expect(meshErrorText(conflict, reason: ''), '设备数已达上限');
      expect(meshErrorText(const MeshApiException(429, 'x')), contains('稍后再试'));
      expect(meshErrorText(const MeshApiException(503, 'x')), contains('稍后再试'));
      expect(meshErrorText(const MeshApiException(502, 'x')), '主控暂时连不上组网服务，稍后再试');
      expect(meshErrorText(const MeshApiException(403, 'forbidden'), reason: 'not_admin'), contains('没有对这个账号开放'));
      expect(meshErrorText(const MeshApiException(400, '名称不合法')), '名称不合法');
    });

    test('429 / 503 的退避：15 秒起翻倍，封顶 5 分钟', () {
      expect(meshBackoff(1), const Duration(seconds: 15));
      expect(meshBackoff(2), const Duration(seconds: 30));
      expect(meshBackoff(3), const Duration(seconds: 60));
      expect(meshBackoff(5), const Duration(seconds: 240));
      expect(meshBackoff(6), const Duration(minutes: 5));
      expect(meshBackoff(20), const Duration(minutes: 5));
      expect(meshBackoff(0), const Duration(seconds: 15));
    });
  });
}
