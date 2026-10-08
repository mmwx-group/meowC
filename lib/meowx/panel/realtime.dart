import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bett_box/common/common.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'client.dart';
import 'crypto.dart';

/// 断线重连的退避：连续失败依次等 5 → 10 → 20 → 40 秒，之后封顶 60 秒。
/// 主控连不上（没网、被拦）或鉴权被拒时，原来固定 5 秒一次的重连会一直空转（每次一轮握手、唤醒一次射频）。
/// 一条连接稳住 [stableAfter] 以上才算「连上过」并复位——鉴权被拒时主控是握手成功后立刻关，那种不能算。
class ReconnectBackoff {
  static const stableAfter = Duration(seconds: 30);
  static const _maxSeconds = 60;

  int _failures = 0;

  /// 一条连接断开（或压根没连上）之后调用，返回下次重连前等多久。[uptime] 是它活了多久，没连上传 null。
  Duration next({Duration? uptime}) {
    if (uptime != null && uptime >= stableAfter) _failures = 0;
    final seconds = 5 << (_failures < 4 ? _failures : 4);
    _failures++;
    return Duration(seconds: seconds > _maxSeconds ? _maxSeconds : seconds);
  }

  /// 网络变了：之前的失败不再说明问题，从头退避。
  void reset() => _failures = 0;
}

/// 主控实时通道 `wss://host/api/secure/ws`：
/// 帧 1 明文 ePub(32B)；帧 2 加密 `{ts, nonce, token?}`；此后每帧 `counter‖ct‖tag`；55s 加密 ping；
/// 断线按 [ReconnectBackoff] 退避重连，网络变化时立刻重连。
class RealtimeClient {
  RealtimeClient({required this.client, required this.token, required this.onEvent});

  /// 加密 ping 的间隔。主控对这条通道的空闲窗口是 70 秒（appWSIdleWindow），必须小于它，
  /// 留出余量给迟到的定时器（后台 / 息屏时会迟到）。原来是 25 秒，多出来的只是射频唤醒。
  static const pingInterval = Duration(seconds: 55);

  final PanelClient client;
  final String token;
  final void Function(String type, Map<String, dynamic> json) onEvent;

  WebSocketChannel? _channel;
  SecureSession? _session;
  Timer? _ping, _reconnect;
  bool _running = false;
  final _backoff = ReconnectBackoff();
  DateTime? _connectedAt;
  StreamSubscription<Object?>? _networkSub;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    // 网络变了（换 Wi-Fi / 蜂窝、恢复联网）不等完退避：正等着重连的话立刻连
    _networkSub = Connectivity().onConnectivityChanged.listen((_) => _onNetworkChanged(), onError: (_) {});
    unawaited(_connect());
  }

  void _onNetworkChanged() {
    if (!_running || _reconnect == null) return;
    _reconnect?.cancel();
    _reconnect = null;
    _backoff.reset();
    unawaited(_connect());
  }

  Future<void> stop() async {
    _running = false;
    _ping?.cancel();
    _reconnect?.cancel();
    _ping = _reconnect = null;
    unawaited(_networkSub?.cancel());
    _networkSub = null;
    final ch = _channel;
    _channel = null;
    _session = null;
    await ch?.sink.close();
  }

  Future<void> _connect() async {
    if (!_running) return;
    try {
      final masterPub = await client.masterPub();
      final ephemeral = await MeowCrypto.newEphemeral();
      final uri = Uri.parse(client.base).replace(scheme: 'wss', path: '/api/secure/ws');
      final ch = IOWebSocketChannel.connect(
        uri,
        customClient: HttpClient()..findProxy = (_) => 'DIRECT',
        connectTimeout: const Duration(seconds: 15),
      );
      await ch.ready;
      if (!_running) {
        await ch.sink.close();
        return;
      }
      _channel = ch;
      final session = await SecureSession.create(ephemeral: ephemeral, masterPub: masterPub);
      _session = session;
      ch.sink.add(Uint8List.fromList((await ephemeral.extractPublicKey()).bytes));
      ch.sink.add(await session.seal(utf8.encode(json.encode({
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'nonce': DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        if (token.isNotEmpty) 'token': token,
      }))));
      _connectedAt = DateTime.now();
      _ping = Timer.periodic(pingInterval, (_) => _send({'type': 'ping'}));
      ch.stream.listen(_onFrame, onError: (_) => _scheduleReconnect(), onDone: _scheduleReconnect, cancelOnError: true);
      commonPrint.log('realtime connected: ${uri.host}');
    } catch (e) {
      commonPrint.log('realtime connect failed: $e');
      _scheduleReconnect();
    }
  }

  Future<void> _send(Map<String, dynamic> obj) async {
    final ch = _channel;
    final s = _session;
    if (ch == null || s == null) return;
    try {
      ch.sink.add(await s.seal(utf8.encode(json.encode(obj))));
    } catch (e) {
      commonPrint.log('realtime send failed: $e');
    }
  }

  Future<void> _onFrame(dynamic data) async {
    final s = _session;
    if (s == null) return;
    final bytes = switch (data) {
      List<int> b => b,
      String str => base64.decode(str),
      _ => null,
    };
    if (bytes == null) return;
    try {
      final plain = json.decode(utf8.decode(await s.open(bytes)));
      if (plain is Map) {
        final m = plain.cast<String, dynamic>();
        onEvent(m['type']?.toString() ?? '', m);
      }
    } catch (e) {
      commonPrint.log('realtime frame dropped: $e');
    }
  }

  void _scheduleReconnect() {
    _ping?.cancel();
    _ping = null;
    _channel = null;
    _session = null;
    final connectedAt = _connectedAt;
    _connectedAt = null;
    if (!_running || _reconnect != null) return;
    final delay = _backoff.next(uptime: connectedAt == null ? null : DateTime.now().difference(connectedAt));
    _reconnect = Timer(delay, () {
      _reconnect = null;
      unawaited(_connect());
    });
  }
}
