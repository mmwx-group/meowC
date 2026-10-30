import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/haptics.dart';
import 'speed_board.dart';
import 'speed_test_network.dart';

/// 测速出站「直连」：mihomo 的内置出站 DIRECT（不是代理组），经本机网络直接测。
const kSpeedTestDirect = 'DIRECT';

/// 界面上的出站名：DIRECT 显示「直连」
String speedTestDisplayName(String name) => name == kSpeedTestDirect ? '直连' : name;

/// 节点协议的显示名（只到顶层，不带 REALITY / WS / gRPC 这些外层，与 iOS / macOS 同一张表）：
/// 核心的 proxies 里 [type] 是 mihomo 的写法（「Vless」「Shadowsocks」「Hysteria2」…），配置里是小写（「vless」「ss」…），
/// 两种都认（不分大小写）；表里没有的原样显示；空 / null（直连）没有协议。
String? speedTestProtocolTitle(String? type) {
  final t = type?.trim();
  if (t == null || t.isEmpty) return null;
  return switch (t.toLowerCase()) {
    'ss' || 'shadowsocks' => 'Shadowsocks',
    'vmess' => 'VMess',
    'vless' => 'VLESS',
    'trojan' => 'Trojan',
    'hysteria2' => 'Hysteria2',
    'hysteria' => 'Hysteria',
    'tuic' => 'TUIC',
    'socks5' => 'SOCKS5',
    'http' => 'HTTP',
    'anytls' => 'AnyTLS',
    'mieru' => 'Mieru',
    'wireguard' => 'WireGuard',
    'miu' => 'Miu',
    'snell' => 'Snell',
    'ssh' => 'SSH',
    _ => t,
  };
}

/// 测速源（与 iOS / macOS 同一组）。Google、Microsoft 只有下载（都是一个大文件按 Range 分段下）。
enum SpeedTestSource {
  google('Google'),
  microsoft('Microsoft'),
  apple('Apple'),
  speedtest('Speedtest'),
  cloudflare('Cloudflare');

  const SpeedTestSource(this.title);
  final String title;

  bool get hasUpload => this != SpeedTestSource.google && this != SpeedTestSource.microsoft;
}

/// 测速出站的出口（核心在准备阶段经同一出站查 speed.cloudflare.com/meta）：界面显示「AS2516 KDDI · 203.0.113.8」。
/// 字段同 component/speedtest 的 ExitInfo；测速记录里原样存一份。
@immutable
class SpeedTestExit {
  const SpeedTestExit({required this.ip, this.asn, this.org, this.country});

  final String ip;
  final int? asn;

  /// 运营商（Cloudflare 的 asOrganization）、国家码
  final String? org, country;

  /// 「AS2516」；没有 ASN 时 null
  String? get asnTag => asn == null || asn == 0 ? null : 'AS$asn';

  /// 「KDDI · 203.0.113.8」（没有运营商名就只有 IP）
  String get label => [if (org != null && org!.isNotEmpty) org!, ip].join(' · ');

  /// 运营商名去掉公司后缀（Limited / Ltd / Inc / Co., Ltd …）：「Hong Kong Telecommunications (HKT) Limited」→
  /// 「Hong Kong Telecommunications (HKT)」。只给界面用，记录里存原文。同 iOS 的 `SpeedTestExit.shortOrganization`。
  String? get shortOrg {
    var name = org?.trim() ?? '';
    if (name.isEmpty) return null;
    const suffixes = ['co., ltd.', 'co.,ltd.', 'co., ltd', 'co.,ltd', 'company limited', 'pte. ltd.', 'pte ltd',
        'limited', 'ltd.', 'ltd', 'inc.', 'inc', 'corporation', 'corp.', 'corp', 'llc', 'gmbh', 's.a.', 'b.v.'];
    var trimmed = true;
    while (trimmed) {
      trimmed = false;
      final lower = name.toLowerCase();
      for (final suffix in suffixes) {
        if (!lower.endsWith(' $suffix') && !lower.endsWith(',$suffix')) continue;
        final cut = name.substring(0, name.length - suffix.length).replaceAll(RegExp(r'[ ,]+$'), '');
        if (cut.isNotEmpty) {
          name = cut;
          trimmed = true;
        }
        break;
      }
    }
    return name;
  }

  /// 出口第二行：「203.0.113.8 · JP」
  String get ipLine => [ip, if (country != null && country!.isNotEmpty) country!].join(' · ');

  static String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;

  /// 没有 ip（或不是对象）返回 null
  static SpeedTestExit? fromJson(Object? j) {
    if (j is! Map) return null;
    final ip = _s(j['ip']);
    if (ip == null) return null;
    return SpeedTestExit(
      ip: ip,
      asn: (j['asn'] as num?)?.toInt(),
      org: _s(j['org']),
      country: _s(j['country']),
    );
  }

  Map<String, Object?> toJson() => {
    'ip': ip,
    'asn': ?asn,
    'org': ?org,
    'country': ?country,
  };
}

/// 测速进度 / 结果（核心 meowSpeedTestStatus 回的 JSON，字段同 component/speedtest 的 Progress）。速率单位 Mbps。
@immutable
class SpeedTestProgress {
  const SpeedTestProgress({
    this.runID = 0,
    this.phase = 'idle',
    this.source,
    this.via,
    this.server,
    this.latencyMs,
    this.downloadMbps,
    this.uploadMbps,
    this.downloadPeakMbps,
    this.uploadPeakMbps,
    this.currentMbps = 0,
    this.downloadSamples = const [],
    this.uploadSamples = const [],
    this.phaseProgress = 0,
    this.bytesUsed = 0,
    this.error,
    this.exit,
    this.exitPending = false,
    this.durationMs,
  });

  final int runID;

  /// idle preparing latency download upload done failed cancelled
  final String phase;
  final SpeedTestSource? source;
  final String? via, server, error;
  final int? latencyMs;
  final double? downloadMbps, uploadMbps, downloadPeakMbps, uploadPeakMbps;
  final double currentMbps, phaseProgress;
  final List<double> downloadSamples, uploadSamples;
  final int bytesUsed;

  /// 出口（查到才有）；[exitPending] = 还在查
  final SpeedTestExit? exit;
  final bool exitPending;

  /// 测完时核心给的时长（从测延迟开始到测完，毫秒）；旧核心没有
  final int? durationMs;

  bool get isRunning => const {'preparing', 'latency', 'download', 'upload'}.contains(phase);

  static double? _d(Object? v) => v is num ? v.toDouble() : null;
  static List<double> _list(Object? v) => v is List ? [for (final e in v) if (e is num) e.toDouble()] : const [];

  factory SpeedTestProgress.fromJson(Map<String, Object?> j) => SpeedTestProgress(
    runID: (j['runID'] as num?)?.toInt() ?? 0,
    phase: j['phase'] as String? ?? 'idle',
    source: SpeedTestSource.values.where((s) => s.name == j['source']).firstOrNull,
    via: j['via'] as String?,
    server: j['server'] as String?,
    latencyMs: (j['latencyMs'] as num?)?.toInt(),
    downloadMbps: _d(j['downloadMbps']),
    uploadMbps: _d(j['uploadMbps']),
    downloadPeakMbps: _d(j['downloadPeakMbps']),
    uploadPeakMbps: _d(j['uploadPeakMbps']),
    currentMbps: _d(j['currentMbps']) ?? 0,
    downloadSamples: _list(j['downloadSamples']),
    uploadSamples: _list(j['uploadSamples']),
    phaseProgress: _d(j['phaseProgress']) ?? 0,
    bytesUsed: (j['bytesUsed'] as num?)?.toInt() ?? 0,
    error: (j['error'] as String?)?.isEmpty == true ? null : j['error'] as String?,
    exit: SpeedTestExit.fromJson(j['exit']),
    exitPending: j['exitPending'] == true,
    durationMs: (j['durationMs'] as num?)?.toInt(),
  );

  SpeedTestProgress copyWith({String? phase, double? currentMbps}) => SpeedTestProgress(
    runID: runID,
    phase: phase ?? this.phase,
    source: source,
    via: via,
    server: server,
    latencyMs: latencyMs,
    downloadMbps: downloadMbps,
    uploadMbps: uploadMbps,
    downloadPeakMbps: downloadPeakMbps,
    uploadPeakMbps: uploadPeakMbps,
    currentMbps: currentMbps ?? this.currentMbps,
    downloadSamples: downloadSamples,
    uploadSamples: uploadSamples,
    phaseProgress: phaseProgress,
    bytesUsed: bytesUsed,
    error: error,
    exit: exit,
    exitPending: exitPending,
    durationMs: durationMs,
  );
}

/// 测速页的状态：测在 Go 核心里跑（meowSpeedTestStart / Status / Stop），这里发开始 / 停止、测的时候每 300ms 拉一次进度。
/// 测速源与单 / 多线程记在本机偏好里。
///
/// 测速榜（speed_board.dart）：同意与否（[boardConsent]）与本机随机 ID 也记在本机偏好里（退出登录不清）；同意时测完自动上传，
/// 记录详情里可重试、上传单条、从测速榜删除。上传的凭证由页面注入（[SpeedBoardUploader.grant]，要读账户与主控）。
class SpeedTestController extends ChangeNotifier {
  SpeedTestController({this.call, this.networkProbe, this.clientInfo, SpeedBoardEndpoint? boardEndpoint, DateTime Function()? now})
    : _boardEndpoint = boardEndpoint,
      _now = now;

  /// 调核心（测试里换成假的）；缺省走 clashCore
  final Future<String?> Function(ActionMethod method, String data)? call;

  /// 取本机网络（测试里换成假的）；缺省 [currentSpeedTestNetwork]
  final Future<String?> Function()? networkProbe;

  /// 上传正文里的平台 / 版本（测试里换成假的）；缺省按本机平台与 App 版本
  final SpeedBoardClientInfo Function()? clientInfo;

  final SpeedBoardEndpoint? _boardEndpoint;
  final DateTime Function()? _now;

  /// 测速榜的上传 / 删除（经核心 meowSpeedTestBoard；核心整次 10 秒超时，桥层多留几秒）
  late final SpeedBoardUploader board = SpeedBoardUploader(
    send: (data) => _invoke(ActionMethod.meowSpeedTestBoard, data, const Duration(seconds: 15)),
    endpoint: _boardEndpoint,
    now: _now,
  );

  static const multiConnections = 8;

  /// 「在浏览器打开网页测速」（与 Bettbox 同一个地址）
  static const webUrl = 'https://ptclspeed.speedtestcustom.com';

  static const _kSource = 'meowx.speedTest.source';
  static const _kMulti = 'meowx.speedTest.multi';
  static const _kBoardUpload = 'meowx.speedTest.upload';
  static const _kBoardInstallId = 'meowx.speedTest.installId';

  SpeedTestSource source = SpeedTestSource.google;
  bool multiThread = false;

  /// 测速节点：节点或 DIRECT（直连，不能选代理组）；null = 首页当前出口实际在用的节点
  String? node;

  /// 测速记录（测完 / 失败才记，见 [SpeedTestHistory]）
  final SpeedTestHistory history = SpeedTestHistory();

  SpeedTestProgress progress = const SpeedTestProgress();

  /// 这次测速的本机网络（Wi-Fi / 5G …，见 speed_test_network.dart）：点开始那一刻取，取不到 null；记进这次的记录
  String? network;

  /// 这次测速节点的协议显示名（[speedTestProtocolTitle]，页面按选的出站在当前配置的 proxies 里查到 type 后传给 [start]）；
  /// 直连 / 查不到 null；记进这次的记录
  String? protocol;

  /// 同上，规格码（[speedBoardProtocolCode]，测速榜上传用）
  String? protocolCode;

  /// 上传到测速榜：null = 还没问过（进测速页弹一次同意卡片）/ true / false
  bool? boardConsent;

  /// 本机偏好读完了（读完才知道要不要弹同意卡片）
  bool prefsLoaded = false;

  String? _installId;

  /// 正在上传 / 删除的记录
  final Set<String> _boardBusy = {};

  /// 没能开始的原因（未连接、核心太旧…）
  String? message;
  bool _starting = false;
  int _generation = 0;

  /// 本次 App 运行里最后一次测完（测完 / 失败）记下的那条记录的 id；开测时清掉
  String? _lastRecordId;

  bool get isRunning => _starting || progress.isRunning;

  /// 测速页页头「分享」这次结果的那条记录：没在测、这次是测完（不是失败 / 停掉）、记下的那条还在记录里（没被删），否则 null。
  /// 能不能出分享图页面再按 SpeedTestShareImage.canShare 判断。
  SpeedTestRecord? get shareableRecord {
    final id = _lastRecordId;
    if (id == null || isRunning || progress.phase != 'done') return null;
    return history.byId(id);
  }

  /// 读本机偏好与测速记录；同时几处调用等的是同一次（页面读完才知道要不要弹测速榜的同意卡片）
  Future<void> load() => _loading ??= _load();
  Future<void>? _loading;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    source = SpeedTestSource.values.where((s) => s.name == prefs.getString(_kSource)).firstOrNull ?? source;
    multiThread = prefs.getBool(_kMulti) ?? multiThread;
    boardConsent = prefs.getBool(_kBoardUpload);
    _installId = prefs.getString(_kBoardInstallId);
    prefsLoaded = true;
    notifyListeners();
    await history.load();
  }

  /// 同意 / 不同意上传到测速榜（第一次进测速页的卡片、测速页的开关）。只管之后测完的，以前的记录不补传。
  void setBoardConsent(bool value) {
    boardConsent = value;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool(_kBoardUpload, value));
  }

  /// 「重置测速榜身份」：换一个本机随机 ID（已上传的结果不受影响，本机记录里的删除凭据照样能用）
  Future<void> resetBoardIdentity() async {
    _installId = newSpeedBoardInstallId();
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_kBoardInstallId, _installId!);
  }

  Future<String> _boardInstallId() async {
    final existing = _installId;
    if (existing != null && existing.isNotEmpty) return existing;
    final id = newSpeedBoardInstallId();
    _installId = id;
    try {
      await (await SharedPreferences.getInstance()).setString(_kBoardInstallId, id);
    } catch (_) {}
    return id;
  }

  SpeedBoardClientInfo _client() {
    final custom = clientInfo;
    if (custom != null) return custom();
    var version = '';
    try {
      version = globalState.packageInfo.version;
    } catch (_) {}
    return SpeedBoardClientInfo(platform: Platform.isAndroid ? 'android' : 'windows', version: version);
  }

  /// 这条记录正在上传或删除
  bool boardBusy(String id) => _boardBusy.contains(id);

  /// 上传一条记录到测速榜（测完自动、重试、记录详情的「上传这条」都走这里）：先标「上传中」，传完换成结果。
  /// 失败的测速、没有节点协议的记录不传；同一条在传的时候不重复传。
  Future<void> uploadToBoard(String id) async {
    final record = history.byId(id);
    if (record == null || _boardBusy.contains(id) || speedBoardBlocker(record) != null) return;
    _boardBusy.add(id);
    history.replace(record.withBoard(SpeedBoardEntry.uploading));
    SpeedBoardEntry entry;
    try {
      entry = await board.upload(record, installId: await _boardInstallId(), client: _client());
    } catch (e) {
      entry = SpeedBoardEntry.failure('上传失败：$e');
    } finally {
      _boardBusy.remove(id);
    }
    final latest = history.byId(id);
    if (latest != null) history.replace(latest.withBoard(entry));
  }

  /// 从测速榜删除（凭上传时拿到的删除凭据，只删服务端那份，本机记录还在）。删掉了回 null，否则是原因。
  Future<String?> deleteFromBoard(String id) async {
    final record = history.byId(id);
    if (record == null || record.board?.isUploaded != true || _boardBusy.contains(id)) return null;
    _boardBusy.add(id);
    notifyListeners();
    try {
      final result = await board.delete(record);
      switch (result) {
        case SpeedBoardDeleted():
          final latest = history.byId(id);
          if (latest != null) history.replace(latest.withBoard(null));
          return null;
        case SpeedBoardDeleteFailed(:final message):
          return message;
      }
    } catch (e) {
      return '删除失败：$e';
    } finally {
      _boardBusy.remove(id);
      notifyListeners();
    }
  }

  void setSource(SpeedTestSource value) {
    source = value;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString(_kSource, value.name));
  }

  void setMultiThread(bool value) {
    multiThread = value;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool(_kMulti, value));
  }

  void setNode(String value) {
    node = value;
    notifyListeners();
  }

  Future<String?> _invoke(ActionMethod method, [String data = '', Duration timeout = const Duration(seconds: 10)]) {
    if (call != null) return call!(method, data);
    return clashCore.clashInterface.invoke<String?>(method: method, data: data, timeout: timeout);
  }

  /// 「用同样设置再测一次」：测速源、线程、节点照这条记录填好（回到测速页由用户点开始）
  void prefill(SpeedTestRecord record) {
    node = record.outbound;
    setMultiThread(record.connections > 1);
    setSource(record.source);
  }

  /// [protocol] 是选的节点的协议显示名（[speedTestProtocolTitle]），[protocolCode] 是规格码（[speedBoardProtocolCode]），
  /// 直连 / 查不到不传
  Future<void> start(String via, {String? protocol, String? protocolCode}) async {
    if (isRunning) return;
    MeowHaptics.tap();
    final generation = ++_generation;
    // 记录用发起时的参数（进度里的 source / via 是核心回的，可能缺）
    final source = this.source;
    final connections = multiThread ? multiConnections : 1;
    message = null;
    _lastRecordId = null;
    _starting = true;
    progress = SpeedTestProgress(phase: 'preparing', source: source, via: via, exitPending: true);
    network = null;
    this.protocol = via == kSpeedTestDirect ? null : protocol;
    this.protocolCode = via == kSpeedTestDirect ? null : protocolCode;
    notifyListeners();
    // 本机网络不等：和开测并行取（几毫秒），取到了「已用」那一行前面出现、测完记进记录
    unawaited((networkProbe ?? currentSpeedTestNetwork)().then((value) {
      if (generation != _generation || value == null) return;
      network = value;
      notifyListeners();
    }));
    String? reason;
    try {
      reason = await _invoke(
        ActionMethod.meowSpeedTestStart,
        json.encode({'source': source.name, 'proxy': via, 'connections': connections}),
      );
    } catch (e) {
      reason = '核心没有响应：$e';
    }
    if (generation != _generation) return;
    // 比 App 旧的核心不认识这个方法：回包是 null
    if (reason == null || reason.isNotEmpty) {
      MeowHaptics.error();   // 没能开始也算失败
      _starting = false;
      progress = const SpeedTestProgress();
      message = reason ?? '核心版本过旧，重启后再试';
      notifyListeners();
      return;
    }
    _starting = false;
    while (generation == _generation) {
      try {
        final raw = await _invoke(ActionMethod.meowSpeedTestStatus);
        if (generation != _generation) return;
        if (raw != null && raw.isNotEmpty) {
          progress = SpeedTestProgress.fromJson(json.decode(raw) as Map<String, Object?>);
          notifyListeners();
          if (!progress.isRunning) {
            // 测完 / 失败才震一下、记一条，一次测速只到这里一回（停止的是 cancelled，且 stop 已让 generation 失效）
            switch (progress.phase) {
              case 'done':
                MeowHaptics.success();
              case 'failed':
                MeowHaptics.error();
            }
            final record = SpeedTestRecord.fromProgress(
              progress,
              source: source,
              connections: connections,
              outbound: via,
              network: network,
              protocol: this.protocol,
              protocolCode: this.protocolCode,
            );
            if (record != null) {
              _lastRecordId = record.id; // 先记上再加：页面听 history 的通知时就取得到
              history.add(record);
              // 同意了才传，只传测完的（失败的不传）
              if (!record.failed && boardConsent == true) unawaited(uploadToBoard(record.id));
            }
            return;
          }
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  void stop() {
    _generation++;
    if (!isRunning) return;
    _starting = false;
    progress = progress.copyWith(phase: 'cancelled', currentMbps: 0);
    notifyListeners();
    unawaited(_invoke(ActionMethod.meowSpeedTestStop).catchError((_) => null));
  }
}

/// 一次测速的记录（测完或失败才记，中途停止的不记）。只存本机，见 [SpeedTestHistory]。
@immutable
class SpeedTestRecord {
  const SpeedTestRecord({
    required this.id,
    required this.date,
    required this.source,
    required this.connections,
    required this.outbound,
    this.via,
    this.server,
    this.latencyMs,
    this.downloadMbps,
    this.uploadMbps,
    this.downloadPeakMbps,
    this.uploadPeakMbps,
    this.downloadSamples = const [],
    this.uploadSamples = const [],
    this.bytesUsed = 0,
    this.error,
    this.exit,
    this.network,
    this.protocol,
    this.protocolCode,
    this.durationMs,
    this.board,
  });

  final String id;
  final DateTime date;
  final SpeedTestSource source;
  final int connections;

  /// 选的出站：节点名，或 [kSpeedTestDirect]（直连）
  final String outbound;

  /// 实际经由的叶子节点（与 [outbound] 相同或更具体）
  final String? via, server;
  final int? latencyMs;
  final double? downloadMbps, uploadMbps, downloadPeakMbps, uploadPeakMbps;

  /// 速率采样，压到至多 [SpeedTestHistory.maxSamples] 个点（详情页画曲线、列表画迷你曲线）
  final List<double> downloadSamples, uploadSamples;
  final int bytesUsed;

  /// 失败原因；null = 测完了
  final String? error;

  /// 出口（ASN / 运营商 / IP）；旧记录与没查到的是 null
  final SpeedTestExit? exit;

  /// 本机网络「Wi-Fi」「5G」「移动数据」「有线网络」…（点开始那一刻的）；旧记录与没取到的是 null
  final String? network;

  /// 节点协议的显示名「VLESS」「Shadowsocks」…（[speedTestProtocolTitle]，只到顶层）；直连、旧记录与查不到的是 null
  final String? protocol;

  /// 节点协议的规格码「vless」「ss」…（[speedBoardProtocolCode]，测速榜上传用）；直连、旧记录与查不到的是 null
  final String? protocolCode;

  /// 从测延迟开始到测完的毫秒数（核心测完时给）；旧记录、旧核心没有
  final int? durationMs;

  /// 测速榜上的状态（上传中 / 已上传 / 失败）；没传过、从测速榜删掉了是 null
  final SpeedBoardEntry? board;

  /// 上传测速榜用的协议码：新记录记着码；旧记录只有显示名，按显示名换回码（「VLESS」→ vless、「Shadowsocks」→ ss）
  String? get boardProtocol => isDirect ? null : (protocolCode ?? speedBoardProtocolCode(protocol));

  bool get isDirect => outbound == kSpeedTestDirect;
  bool get failed => error != null;

  /// 列表、筛选胶囊里显示的名字：直连显示「直连」
  String get displayName => speedTestDisplayName(outbound);

  static final _random = Random();

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${_random.nextInt(1 << 32).toRadixString(16)}';

  /// 从核心的进度（done / failed）生成记录；其它阶段（没测完、被停掉）返回 null
  static SpeedTestRecord? fromProgress(
    SpeedTestProgress p, {
    required SpeedTestSource source,
    required int connections,
    required String outbound,
    String? network,
    String? protocol,
    String? protocolCode,
    DateTime? date,
  }) {
    if (p.phase != 'done' && p.phase != 'failed') return null;
    return SpeedTestRecord(
      id: newId(),
      date: date ?? DateTime.now(),
      source: source,
      connections: connections,
      outbound: outbound,
      via: p.via,
      server: p.server,
      latencyMs: p.latencyMs,
      downloadMbps: p.downloadMbps,
      uploadMbps: p.uploadMbps,
      downloadPeakMbps: p.downloadPeakMbps,
      uploadPeakMbps: p.uploadPeakMbps,
      downloadSamples: SpeedTestHistory.downsample(p.downloadSamples),
      uploadSamples: SpeedTestHistory.downsample(p.uploadSamples),
      bytesUsed: p.bytesUsed,
      error: p.phase == 'failed' ? (p.error ?? '未知原因') : null,
      exit: p.exit,
      network: network,
      protocol: protocol,
      protocolCode: protocolCode,
      durationMs: p.phase == 'done' ? p.durationMs : null,
    );
  }

  /// 换掉测速榜状态（null = 清掉远端字段，本机记录保留）
  SpeedTestRecord withBoard(SpeedBoardEntry? board) => SpeedTestRecord(
    id: id,
    date: date,
    source: source,
    connections: connections,
    outbound: outbound,
    via: via,
    server: server,
    latencyMs: latencyMs,
    downloadMbps: downloadMbps,
    uploadMbps: uploadMbps,
    downloadPeakMbps: downloadPeakMbps,
    uploadPeakMbps: uploadPeakMbps,
    downloadSamples: downloadSamples,
    uploadSamples: uploadSamples,
    bytesUsed: bytesUsed,
    error: error,
    exit: exit,
    network: network,
    protocol: protocol,
    protocolCode: protocolCode,
    durationMs: durationMs,
    board: board,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'date': date.millisecondsSinceEpoch / 1000,
    'source': source.name,
    'connections': connections,
    'outbound': outbound,
    'via': ?via,
    'server': ?server,
    'latencyMs': ?latencyMs,
    'downloadMbps': ?downloadMbps,
    'uploadMbps': ?uploadMbps,
    'downloadPeakMbps': ?downloadPeakMbps,
    'uploadPeakMbps': ?uploadPeakMbps,
    'downloadSamples': downloadSamples,
    'uploadSamples': uploadSamples,
    'bytesUsed': bytesUsed,
    'error': ?error,
    'exit': ?exit?.toJson(),
    'network': ?network,
    'protocol': ?protocol,
    'protocolCode': ?protocolCode,
    'durationMs': ?durationMs,
    'board': ?board?.toJson(),
  };

  /// 字段不全（id / 时间 / 出站缺了）返回 null，读盘时跳过
  static SpeedTestRecord? fromJson(Map<String, Object?> j) {
    final id = j['id'], date = j['date'], outbound = j['outbound'];
    if (id is! String || date is! num || outbound is! String) return null;
    return SpeedTestRecord(
      id: id,
      date: DateTime.fromMillisecondsSinceEpoch((date * 1000).round()),
      source: SpeedTestSource.values.where((s) => s.name == j['source']).firstOrNull ?? SpeedTestSource.google,
      connections: (j['connections'] as num?)?.toInt() ?? 1,
      outbound: outbound,
      via: j['via'] as String?,
      server: j['server'] as String?,
      latencyMs: (j['latencyMs'] as num?)?.toInt(),
      downloadMbps: SpeedTestProgress._d(j['downloadMbps']),
      uploadMbps: SpeedTestProgress._d(j['uploadMbps']),
      downloadPeakMbps: SpeedTestProgress._d(j['downloadPeakMbps']),
      uploadPeakMbps: SpeedTestProgress._d(j['uploadPeakMbps']),
      downloadSamples: SpeedTestProgress._list(j['downloadSamples']),
      uploadSamples: SpeedTestProgress._list(j['uploadSamples']),
      bytesUsed: (j['bytesUsed'] as num?)?.toInt() ?? 0,
      error: j['error'] as String?,
      exit: SpeedTestExit.fromJson(j['exit']),
      network: j['network'] as String?,
      protocol: j['protocol'] as String?,
      protocolCode: j['protocolCode'] as String?,
      durationMs: (j['durationMs'] as num?)?.toInt(),
      board: SpeedBoardEntry.fromJson(j['board']),
    );
  }

  /// 「单线程」/「8 线程」
  String get threadsTitle => connections > 1 ? '$connections 线程' : '单线程';

  /// 「10月18日」
  String get dayTitle => '${date.month}月${date.day}日';

  /// 「21:42」
  String get timeTitle => '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

/// 测速记录里速率的写法：100 以上取整，以下一位小数（与 iOS 的 SpeedTestRecord.mbps 一致；测速读数用 [fmtMbps]）
String fmtRecordMbps(double? v) => v == null ? '–' : (v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1));

/// 汇总卡：最近 30 天的次数、三项最好成绩、下载走势
@immutable
class SpeedTestSummary {
  const SpeedTestSummary({
    required this.count,
    this.fastestDownload,
    this.fastestUpload,
    this.lowestLatency,
    this.trend = const [],
  });

  final int count;
  final SpeedTestRecord? fastestDownload, fastestUpload, lowestLatency;

  /// 走势：按时间先后的下载速率（失败的不算）
  final List<double> trend;
}

/// 测速记录（测速页右上角「记录」）：只存本机，SharedPreferences 单键存一个 JSON 数组（每条约 1–2 KB），
/// 最多 [limit] 条、超出删最旧的；退出登录、换订阅都不清。
class SpeedTestHistory extends ChangeNotifier {
  /// [persist] 为 false 时不读写盘（单测用）
  SpeedTestHistory({this.persist = true});

  final bool persist;

  static const limit = 100;
  static const maxSamples = 40;
  static const _kHistory = 'meowx.speedTest.history';

  /// 新的在前
  List<SpeedTestRecord> get records => _records;
  List<SpeedTestRecord> _records = const [];
  bool _loaded = false;

  /// 写盘按先后排队（各自 then 的话，连着两次保存可能是旧的那份后落盘）
  Future<void> _writes = Future.value();

  Future<void> load() async {
    if (_loaded || !persist) return;
    _loaded = true;
    final raw = (await SharedPreferences.getInstance()).getString(_kHistory);
    if (raw == null || raw.isEmpty) return;
    final loaded = <SpeedTestRecord>[];
    try {
      for (final e in json.decode(raw) as List) {
        if (e is Map) {
          final r = SpeedTestRecord.fromJson(e.cast<String, Object?>());
          if (r != null) loaded.add(r);
        }
      }
    } catch (_) {
      return;
    }
    // 读盘前已经记下的（极少见：页面没等 load 就测完了）合在一起
    final ids = {for (final r in _records) r.id};
    _records = ([..._records, ...loaded.where((r) => !ids.contains(r.id))]..sort((a, b) => b.date.compareTo(a.date)))
        .take(limit)
        .toList();
    notifyListeners();
  }

  void add(SpeedTestRecord record) {
    _records = [record, ..._records].take(limit).toList();
    _changed();
  }

  void delete(String id) {
    _records = [for (final r in _records) if (r.id != id) r];
    _changed();
  }

  /// 按 id 换掉一条（测速榜状态变了）；这条已经被删了就什么也不做
  void replace(SpeedTestRecord record) {
    if (byId(record.id) == null) return;
    _records = [for (final r in _records) r.id == record.id ? record : r];
    _changed();
  }

  void clear() {
    _records = const [];
    _changed();
  }

  SpeedTestRecord? byId(String id) => _records.where((r) => r.id == id).firstOrNull;

  void _changed() {
    notifyListeners();
    if (!persist) return;
    final data = json.encode([for (final r in _records) r.toJson()]);
    _writes = _writes.then((_) async {
      try {
        await (await SharedPreferences.getInstance()).setString(_kHistory, data);
      } catch (_) {}
    });
  }

  /// 等排队的写盘都落完（测试用）
  Future<void> flush() => _writes;

  // —— 筛选 / 汇总（界面用，纯函数便于单测）——

  /// 筛选胶囊：「全部」之后是直连（有记录才出现），再按最近一次测的先后列出节点
  static List<String> filterOptions(List<SpeedTestRecord> records) {
    final seen = <String>{};
    final nodes = [for (final r in records) if (!r.isDirect && seen.add(r.outbound)) r.outbound];
    return records.any((r) => r.isDirect) ? [kSpeedTestDirect, ...nodes] : nodes;
  }

  /// [outbound] 为 null = 全部
  static List<SpeedTestRecord> filtered(List<SpeedTestRecord> records, String? outbound) =>
      outbound == null ? records : [for (final r in records) if (r.outbound == outbound) r];

  /// 汇总卡：最近 [days] 天内的记录
  static SpeedTestSummary summary(List<SpeedTestRecord> records, {DateTime? now, int days = 30}) {
    final since = (now ?? DateTime.now()).subtract(Duration(days: days));
    final recent = [for (final r in records) if (!r.date.isBefore(since)) r];
    final ok = [for (final r in recent) if (!r.failed) r];
    SpeedTestRecord? best(Iterable<SpeedTestRecord> list, num Function(SpeedTestRecord) key, {bool lowest = false}) =>
        list.fold<SpeedTestRecord?>(null, (b, r) {
          if (b == null) return r;
          return (lowest ? key(r) < key(b) : key(r) > key(b)) ? r : b;
        });
    return SpeedTestSummary(
      count: recent.length,
      fastestDownload: best(ok.where((r) => r.downloadMbps != null), (r) => r.downloadMbps!),
      fastestUpload: best(ok.where((r) => r.uploadMbps != null), (r) => r.uploadMbps!),
      lowestLatency: best(ok.where((r) => r.latencyMs != null), (r) => r.latencyMs!, lowest: true),
      trend: [
        for (final r in [...ok]..sort((a, b) => a.date.compareTo(b.date)))
          if (r.downloadMbps != null) r.downloadMbps!,
      ],
    );
  }

  /// 全部记录里下载最快的那条（列表角标「最快」）
  static String? fastest(List<SpeedTestRecord> records) {
    SpeedTestRecord? best;
    for (final r in records) {
      if (r.failed || r.downloadMbps == null) continue;
      if (best == null || r.downloadMbps! > best.downloadMbps!) best = r;
    }
    return best?.id;
  }

  /// 按日分组（新的在前）：「今天」「昨天」，更早的「10月15日」（跨年带年份）
  static List<(String, List<SpeedTestRecord>)> groupedByDay(List<SpeedTestRecord> records, {DateTime? now}) {
    final groups = <(String, List<SpeedTestRecord>)>[];
    for (final r in [...records]..sort((a, b) => b.date.compareTo(a.date))) {
      final title = dayTitle(r.date, now: now);
      if (groups.isNotEmpty && groups.last.$1 == title) {
        groups.last.$2.add(r);
      } else {
        groups.add((title, [r]));
      }
    }
    return groups;
  }

  static String dayTitle(DateTime date, {DateTime? now}) {
    final today = now ?? DateTime.now();
    bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
    if (sameDay(date, today)) return '今天';
    // 按日历减一天（跨夏令时也不会错到前天）
    if (sameDay(date, DateTime(today.year, today.month, today.day - 1))) return '昨天';
    return date.year == today.year ? '${date.month}月${date.day}日' : '${date.year}年${date.month}月${date.day}日';
  }

  /// 采样压缩：每段取平均，保留至多 [count] 个点（曲线形状不变，记录体积可控）
  static List<double> downsample(List<double> samples, [int count = maxSamples]) {
    if (samples.length <= count || count <= 0) return samples;
    final size = samples.length / count;
    return [
      for (var i = 0; i < count; i++)
        () {
          final lo = (i * size).floor();
          final hi = max(lo + 1, min(samples.length, ((i + 1) * size).floor()));
          final slice = samples.sublist(lo, hi);
          return slice.reduce((a, b) => a + b) / slice.length;
        }(),
    ];
  }
}

/// 全局一份（测速页关掉再打开，上一次的结果还在）。
final speedTestController = SpeedTestController();

/// Mbps 的显示：<10 两位小数，<100 一位，其余取整。
String fmtMbps(double v) => v < 10 ? v.toStringAsFixed(2) : (v < 100 ? v.toStringAsFixed(1) : v.toStringAsFixed(0));
