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
}
