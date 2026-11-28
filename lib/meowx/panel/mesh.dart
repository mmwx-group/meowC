import 'client.dart';

export 'mesh_relay.dart';

/// 主控 `GET /api/user/mesh/status` 的应答：喵窝能不能用（只认启用中的管理员）。
class MeshPanelStatus {
  const MeshPanelStatus({
    required this.available,
    this.reason = '',
    this.message = '',
    this.controlUrl = '',
    this.magicDns = '',
    this.joinedAdmin = '',
    this.deviceRelay,
    this.accessScope = '',
    this.deviceLimit,
    this.servers = const [],
  });

  final bool available;

  /// 设备中继的主控开关（接口稿 MEOWX_MESH_PEER_RELAY_API.md）。老主控没有这个字段 = null：不支持，隐藏全部中继界面、
  /// 也不调路径 / 中继接口
  final MeshDeviceRelayFlag? deviceRelay;

  /// not_admin / disabled / starting（可用时为空）
  final String reason;
  final String message;

  /// 控制地址：主控套了 CDN 时是不经 CDN 的独立控制入口 / 中继地址（不要用主控网址）
  final String controlUrl;
  final String magicDns;

  /// 加入了哪位管理员的喵窝（用户名）：与他、以及加入他的其它账号在同一网络，设备与站点双向互通。
  /// 空 = 独立喵窝（老主控不发这个字段）
  final String joinedAdmin;

  /// 访问范围：servers（仅服务器）/ sites（服务器 + 管理员站点）/ full（完全互通）；旧主控没有这个字段 = 空（不显示）
  final String accessScope;

  /// 设备上限：0 = 不限；旧主控没有这个字段 = null（不显示）
  final int? deviceLimit;

  /// （预留）可经喵窝连接的服务器：主控将来在 status 里多给的 `servers`；没有 = 空（不显示）
  final List<MeshServer> servers;

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
      joinedAdmin: (r['joined_admin']?.toString() ?? '').trim(),
      deviceRelay: available ? MeshDeviceRelayFlag.parse(r['device_relay']) : null,
      accessScope: (r['access_scope']?.toString() ?? '').trim().toLowerCase(),
      deviceLimit: _int(r['device_limit']),
      servers: [for (final s in (r['servers'] is List ? r['servers'] as List : const [])) ?MeshServer.parse(s)],
    );
  }
}

/// `mesh/status` 的 `device_relay`。
class MeshDeviceRelayFlag {
  const MeshDeviceRelayFlag({this.enabled = false, this.minVersion = '', this.canShare = false});

  /// 管理员开放了设备中继：false 时隐藏中继开关与标签（路径上报与显示照常）
  final bool enabled;

  /// 中继设备要求的 tailscaled 最低版本
  final String minVersion;

  /// 能把中继设成 `share: all`（只有管理员）
  final bool canShare;

  static MeshDeviceRelayFlag? parse(Object? o) {
    if (o is! Map) return null;
    return MeshDeviceRelayFlag(
      enabled: o['enabled'] == true,
      minVersion: o['min_version']?.toString() ?? '',
      canShare: o['can_share'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MeshDeviceRelayFlag && other.enabled == enabled && other.minVersion == minVersion && other.canShare == canShare;

  @override
  int get hashCode => Object.hash(enabled, minVersion, canShare);
}

/// 访问范围的一行文字（喵窝页状态行下）；认不出 / 没有时 null（不显示）。
String? meshAccessScopeText(String scope) => switch (scope) {
  'servers' => '访问范围：仅服务器',
  'sites' => '访问范围：服务器 + 管理员站点',
  'full' => '访问范围：完全互通',
  _ => null,
};

/// 设备上限的显示：0 = 不限。
String meshDeviceLimitText(int limit) => limit <= 0 ? '不限' : '$limit 台';

/// （预留）可经喵窝连接的一台服务器（status 的 `servers[]`）。宽松解析：没有名称或喵窝地址的条目丢掉。
class MeshServer {
  const MeshServer({required this.name, required this.meshIp, this.serverId});

  final String name;

  /// 服务器在喵窝里的地址（100.64.x.y）
  final String meshIp;
  final int? serverId;

  static MeshServer? parse(Object? o) {
    if (o is! Map) return null;
    final name = (o['name']?.toString() ?? '').trim();
    final ip = (o['mesh_ip']?.toString() ?? '').trim();
    if (name.isEmpty || ip.isEmpty) return null;
    return MeshServer(name: name, meshIp: ip, serverId: _int(o['server_id']));
  }
}

/// 主控里的一台设备（`mesh/devices` 的 devices[]，以及同网络里别人的设备 shared_devices[]）。
class MeshDevice {
  const MeshDevice({
    required this.id,
    required this.name,
    this.ipv4 = '',
    this.online = false,
    this.lastSeen,
    this.routes = const [],
    this.pendingRoutes = const [],
    this.dnsName = '',
    this.username = '',
  });

  final int id;
  final String name;
  final String ipv4;
  final bool online;
  final DateTime? lastSeen;

  /// 这台发布并已批准的网段（OpenWrt）；主控给 null 时当空
  final List<String> routes;

  /// 发布了、还没批准的网段；主控给 null 时当空
  final List<String> pendingRoutes;

  /// 设备在喵窝里的 DNS 名（`名字.MagicDNS 后缀`）
  final String dnsName;

  /// 设备主人（只有 shared_devices 带：同网络里别人的设备）
  final String username;

  /// 「站点路由器」：访问范围是 sites 时共享列表里的条目只有已批准的网段，没有地址与 DNS 名（不给复制地址）
  bool get isSiteRouter => ipv4.isEmpty && dnsName.isEmpty && routes.isNotEmpty;

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
      routes: _strings(o['routes']),
      pendingRoutes: _strings(o['pending_routes']),
      dnsName: o['dns_name']?.toString() ?? '',
      username: o['username']?.toString() ?? '',
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
  const MeshDeviceList({this.devices = const [], this.sites = const [], this.sharedDevices = const [], this.complete = true});

  final List<MeshDevice> devices;
  final List<MeshSite> sites;

  /// 同网络里别人的设备（加入了某位管理员的喵窝时；管理员本人这里是加入他的人的设备）。只读：
  /// 主控对它们的改名 / 删除回 404。独立喵窝 / 老主控没有这个字段 = 空
  final List<MeshDevice> sharedDevices;

  /// 主控完整给出了设备列表（Headscale 出错时主控仍回站点、设备不全，带 error）
  final bool complete;

  static MeshDeviceList parse(Map<String, dynamic> r) {
    final err = r['error']?.toString() ?? '';
    // 主控拿到站点、但 Headscale 那边出错时也回 devices / sites（带 error）：照样用
    if (err.isNotEmpty && r['devices'] == null && r['sites'] == null) throw PanelException(err);
    return MeshDeviceList(
      devices: [for (final d in (r['devices'] is List ? r['devices'] as List : const [])) ?MeshDevice.parse(d)],
      sites: [for (final s in (r['sites'] is List ? r['sites'] as List : const [])) ?MeshSite.parse(s)],
      sharedDevices: [for (final d in (r['shared_devices'] is List ? r['shared_devices'] as List : const [])) ?MeshDevice.parse(d)],
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

List<String> _strings(Object? v) => [
  for (final r in (v is List ? v : const []))
    if (r != null && r.toString().trim().isNotEmpty) r.toString().trim(),
];

int? _int(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s),
  _ => null,
};

/// 喵窝管理接口的出错（经加密 RPC，主控保留业务 HTTP 状态码）：[status] 是那个状态码，[message] 是主控给的说明。
class MeshApiException extends PanelException {
  const MeshApiException(this.status, super.message);

  final int status;
}

/// 出错之后该怎么办（规格 A4）。
enum MeshErrorAction {
  /// 401：走登录续期（会话 token 失效）
  relogin,

  /// 403：重查 status（多半已被移出名单：not_admin → 隐藏入口、清掉共享设备）
  recheck,

  /// 409：重查 status，主控关了喵窝或设备数到了上限
  conflict,

  /// 429 / 503：稍后再试（退避）
  backoff,

  /// 502：主控暂时连不上组网服务，保留本机设备身份、不清状态
  unreachable,

  /// 其它（400 / 404 / 连不上主控…）：照主控给的说明
  other,
}

MeshErrorAction meshErrorAction(Object e) {
  final status = e is MeshApiException ? e.status : null;
  return switch (status) {
    401 => MeshErrorAction.relogin,
    403 => MeshErrorAction.recheck,
    409 => MeshErrorAction.conflict,
    429 || 503 => MeshErrorAction.backoff,
    502 => MeshErrorAction.unreachable,
    _ => MeshErrorAction.other,
  };
}

/// 出错时给人看的话。409 要先重查 status：[reason] = 重查后的原因码（disabled = 主控关了喵窝），
/// [deviceLimit] = 设备上限（拿不到时不写台数）；其它码不看这两项。
String meshErrorText(Object e, {String? reason, int? deviceLimit}) => switch (meshErrorAction(e)) {
  MeshErrorAction.relogin => '登录已过期，请重新登录',
  MeshErrorAction.recheck => reason == 'not_admin' ? '喵窝没有对这个账号开放，请联系管理员' : (e is PanelException ? e.message : e.toString()),
  MeshErrorAction.conflict => reason == 'disabled'
      ? '主控已关闭喵窝'
      : (deviceLimit != null && deviceLimit > 0 ? '设备数已达上限（$deviceLimit 台）' : '设备数已达上限'),
  MeshErrorAction.backoff => '主控忙，稍后再试',
  MeshErrorAction.unreachable => '主控暂时连不上组网服务，稍后再试',
  MeshErrorAction.other => e is PanelException ? e.message : e.toString(),
};

/// 429 / 503 之后隔多久再试：15 秒起、每次翻倍，最多 5 分钟（[failures] = 连续第几次，从 1 数）。
Duration meshBackoff(int failures) {
  final n = failures < 1 ? 1 : (failures > 6 ? 6 : failures);
  final d = Duration(seconds: 15 * (1 << (n - 1)));
  return d > const Duration(minutes: 5) ? const Duration(minutes: 5) : d;
}

/// 喵窝的主控接口（都经加密通道、只认名单里的账号）。HTTP 状态码不是 2xx 时抛 [MeshApiException]
/// （status 接口不在名单里时也回 200，按 available / reason 判断）；200 但带 `{"error": …}` 时抛 [PanelException]。
extension MeshPanelApi on PanelClient {
  Future<Map<String, dynamic>> _meshRpc(String path, {String method = 'POST', Map<String, dynamic> payload = const {}, required String token}) async {
    final r = await rpcWithStatus(path, method: method, payload: payload, token: token);
    if (r.status >= 400) {
      final msg = (r.body['error'] ?? r.body['message'])?.toString() ?? '';
      throw MeshApiException(r.status, msg.isEmpty ? '主控回 HTTP ${r.status}' : msg);
    }
    return r.body;
  }

  Future<MeshPanelStatus> meshStatus(String token) async =>
      MeshPanelStatus.parse(await _meshRpc('/user/mesh/status', method: 'GET', token: token));

  Future<MeshDeviceList> meshDevices(String token) async =>
      MeshDeviceList.parse(await _meshRpc('/user/mesh/devices', method: 'GET', token: token));

  /// 申请一把一次性入网 key。[previousNodeId]：这台设备上一次在主控里的编号，主控先删掉它再签新 key
  Future<MeshEnrollment> meshEnroll(
    String token, {
    required String hostname,
    required String os,
    required String version,
    int? previousNodeId,
  }) async => MeshEnrollment.parse(
    await _meshRpc(
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
    final r = await _meshRpc('/user/mesh/devices/$id', method: 'DELETE', token: token);
    final err = r['error']?.toString() ?? '';
    if (err.isNotEmpty) throw PanelException(err);
  }
}
