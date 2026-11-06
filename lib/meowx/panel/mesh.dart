import 'client.dart';

/// 主控 `GET /api/user/mesh/status` 的应答：喵窝能不能用（只认启用中的管理员）。
class MeshPanelStatus {
  const MeshPanelStatus({
    required this.available,
    this.reason = '',
    this.message = '',
    this.controlUrl = '',
    this.magicDns = '',
  });

  final bool available;

  /// not_admin / disabled / starting（可用时为空）
  final String reason;
  final String message;

  /// 控制地址：主控套了 CDN 时是不经 CDN 的独立控制入口 / 中继地址（不要用主控网址）
  final String controlUrl;
  final String magicDns;

  static MeshPanelStatus parse(Map<String, dynamic> r) {
    final err = r['error']?.toString() ?? '';
    if (err.isNotEmpty && r['available'] == null) throw PanelException(err);
    final available = r['available'] == true;
    return MeshPanelStatus(
      available: available,
      reason: available ? '' : (r['reason']?.toString() ?? 'disabled'),
      message: r['message']?.toString() ?? '',
      controlUrl: r['control_url']?.toString() ?? '',
      magicDns: r['magic_dns']?.toString() ?? '',
    );
  }
}

/// 主控里的一台设备（`mesh/devices` 的 devices[]）。
class MeshDevice {
  const MeshDevice({required this.id, required this.name, this.ipv4 = '', this.online = false, this.lastSeen, this.routes = const []});

  final int id;
  final String name;
  final String ipv4;
  final bool online;
  final DateTime? lastSeen;

  /// 这台发布并已批准的网段（OpenWrt）
  final List<String> routes;

  static MeshDevice? parse(Object? o) {
    if (o is! Map) return null;
    final id = _int(o['id']);
    if (id == null) return null;
    final seen = DateTime.tryParse(o['last_seen']?.toString() ?? '');
    return MeshDevice(
      id: id,
      name: o['name']?.toString() ?? '#$id',
      ipv4: o['ipv4']?.toString() ?? '',
      online: o['online'] == true,
      // Headscale 没见过的设备给的是零值时间（0001-01-01）
      lastSeen: seen == null || seen.year < 2000 ? null : seen,
      routes: [for (final r in (o['routes'] is List ? o['routes'] as List : const [])) r.toString()],
    );
  }
}

/// 本账号的站点（OpenWrt 开放的局域网）。
class MeshSite {
  const MeshSite({required this.id, required this.original, required this.advertised, this.mapped = false});

  final int id;
  final String original;

  /// 在喵窝里用的网段：原样开放 = original，映射 = 映射段
  final String advertised;
  final bool mapped;

  static MeshSite? parse(Object? o) {
    if (o is! Map) return null;
    final id = _int(o['id']);
    final original = o['original']?.toString() ?? '';
    if (id == null || original.isEmpty) return null;
    final advertised = o['advertised']?.toString() ?? '';
    return MeshSite(
      id: id,
      original: original,
      advertised: advertised.isEmpty ? original : advertised,
      mapped: o['mapped'] == true,
    );
  }
}

/// `mesh/devices` 的应答。
class MeshDeviceList {
  const MeshDeviceList({this.devices = const [], this.sites = const [], this.complete = true});

  final List<MeshDevice> devices;
  final List<MeshSite> sites;

  /// 主控完整给出了设备列表（Headscale 出错时主控仍回站点、设备不全，带 error）
  final bool complete;

  static MeshDeviceList parse(Map<String, dynamic> r) {
    final err = r['error']?.toString() ?? '';
    // 主控拿到站点、但 Headscale 那边出错时也回 devices / sites（带 error）：照样用
    if (err.isNotEmpty && r['devices'] == null && r['sites'] == null) throw PanelException(err);
    return MeshDeviceList(
      devices: [for (final d in (r['devices'] is List ? r['devices'] as List : const [])) ?MeshDevice.parse(d)],
      sites: [for (final s in (r['sites'] is List ? r['sites'] as List : const [])) ?MeshSite.parse(s)],
      complete: err.isEmpty,
    );
  }
}

/// `mesh/enroll` 的应答：一次性、10 分钟过期的入网 key 与控制地址。
class MeshEnrollment {
  const MeshEnrollment({required this.authKey, this.controlUrl = '', this.magicDns = '', this.sites = const []});

  final String authKey;
  final String controlUrl;
  final String magicDns;
  final List<MeshSite> sites;

  static MeshEnrollment parse(Map<String, dynamic> r) {
    final key = r['auth_key']?.toString() ?? '';
    if (key.isEmpty) throw PanelException(r['error']?.toString() ?? '主控没有给入网 key');
    return MeshEnrollment(
      authKey: key,
      controlUrl: r['control_url']?.toString() ?? '',
      magicDns: r['magic_dns']?.toString() ?? '',
      sites: [for (final s in (r['sites'] is List ? r['sites'] as List : const [])) ?MeshSite.parse(s)],
    );
  }
}

int? _int(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s),
  _ => null,
};

/// 喵窝的主控接口（都经加密通道、只认管理员；出错时主控回 `{"error": …}`，这里抛 [PanelException]）。
extension MeshPanelApi on PanelClient {
  Future<MeshPanelStatus> meshStatus(String token) async =>
      MeshPanelStatus.parse(await rpc('/user/mesh/status', method: 'GET', token: token));

  Future<MeshDeviceList> meshDevices(String token) async =>
      MeshDeviceList.parse(await rpc('/user/mesh/devices', method: 'GET', token: token));

  /// 申请一把一次性入网 key。[previousNodeId]：这台设备上一次在主控里的编号，主控先删掉它再签新 key
  Future<MeshEnrollment> meshEnroll(
    String token, {
    required String hostname,
    required String os,
    required String version,
    int? previousNodeId,
  }) async => MeshEnrollment.parse(
    await rpc(
      '/user/mesh/enroll',
      token: token,
      payload: {
        'hostname': hostname,
        'os': os,
        'client': 'meowx',
        'version': version,
        'previous_node_id': ?previousNodeId,
      },
    ),
  );

  /// 从主控删掉一台设备（退出喵窝用）
  Future<void> meshDeleteDevice(String token, int id) async {
    final r = await rpc('/user/mesh/devices/$id', method: 'DELETE', token: token);
    final err = r['error']?.toString() ?? '';
    if (err.isNotEmpty) throw PanelException(err);
  }
}
