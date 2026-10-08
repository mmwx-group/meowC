import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/clash/message.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不连核心的通道：发出去的请求记下来，回包由测试自己喂给 handleMessage（两端的监听都走它）。
class _Handler extends ClashHandlerInterface {
  final sent = <Map<String, dynamic>>[];

  String get lastId => sent.last['id'] as String;

  @override
  void sendMessage(String message) => sent.add(json.decode(message) as Map<String, dynamic>);

  @override
  FutureOr<void> reStart() {}

  @override
  FutureOr<bool> destroy() => true;

  @override
  Future<bool> preload() async => true;
}

/// 核心回包的信封（Go 侧 ActionResult 的字段顺序：id / method / data / code）。
String _reply(String id, String method, Object? data) => json.encode({'id': id, 'method': method, 'data': data, 'code': 0});

/// 核心推来的消息（id 为空、method = message）。
String _push(String type, Object? data) => _reply('', 'message', {'type': type, 'data': data});

Map<String, dynamic> _connJson(int i) => {
  'id': 'c$i',
  'upload': 1024 * i,
  'download': 4096 * i,
  'start': '2026-10-07T14:02:36.000Z',
  'chains': ['🇭🇰 香港 01 · IEPL', '自动选择', '节点选择'],
  'rule': 'GEOSITE',
  'rulePayload': 'youtube',
  'metadata': {'network': 'tcp', 'type': 'Tun', 'host': 'rr$i---sn-example.googlevideo.com', 'destinationIP': '198.51.100.$i', 'destinationPort': '443'},
};

void main() {
  // safeFuture 的超时与清理定时器在 testWidgets 的假时钟里走，用例末尾把它们推完
  testWidgets('回包到了就把 completer 从表里拿掉，不再留到 30s 后的清理定时器', (tester) async {
    final h = _Handler();
    final memory = h.invoke<String>(method: ActionMethod.getMemory);
    final closed = h.invoke<bool>(method: ActionMethod.closeConnections);
    expect(h.callbackCompleterMap, hasLength(2));

    h.handleMessage(_reply(h.sent[0]['id'] as String, 'getMemory', '60817408'));
    expect(h.callbackCompleterMap.keys, [h.sent[1]['id']]);
    expect(await memory, '60817408');

    h.handleMessage(_reply(h.sent[1]['id'] as String, 'closeConnections', true));
    expect(h.callbackCompleterMap, isEmpty);
    expect(await closed, isTrue);

    // 同一个 id 的回包再来一次（不该有）：找不到 completer，丢掉
    h.handleMessage(_reply(h.sent[0]['id'] as String, 'getMemory', '1'));
    await tester.pump(const Duration(seconds: 31));
    expect(h.callbackCompleterMap, isEmpty);
  });

  testWidgets('一直没有回包：到点给默认值，清理定时器照旧把表项删掉', (tester) async {
    final h = _Handler();
    String? got;
    unawaited(h.invoke<String>(method: ActionMethod.getConnections).then((v) => got = v));
    expect(h.callbackCompleterMap, hasLength(1));

    await tester.pump(const Duration(seconds: 30));
    expect(got, '');
    expect(h.callbackCompleterMap, hasLength(1));
    await tester.pump(commonDuration);
    expect(h.callbackCompleterMap, isEmpty);

    // 超时之后才到的回包没人要了
    h.handleMessage(_reply(h.lastId, 'getConnections', '{"connections":[]}'));
    expect(got, '');
  });

  test('大回包在后台 isolate 解信封，按 id 交回；小消息照旧同步解', () async {
    final h = _Handler();

    // 连接快照：内层 JSON 以字符串嵌在信封里
    final snapshot = json.encode({'connections': [for (var i = 0; i < 200; i++) _connJson(i)]});
    final conns = h.invoke<String>(method: ActionMethod.getConnections, timeout: const Duration(seconds: 5));
    final big = _reply(h.lastId, 'getConnections', snapshot);
    expect(big.length, greaterThan(offMainDecodeThreshold));
    h.handleMessage(big);
    // 异步解：这一刻还没交回
    expect(h.callbackCompleterMap, hasLength(1));

    // 后到的小消息先处理完，不被大包挡住
    final memory = h.invoke<String>(method: ActionMethod.getMemory, timeout: const Duration(seconds: 5));
    h.handleMessage(_reply(h.lastId, 'getMemory', '42'));
    expect(h.callbackCompleterMap, hasLength(1));
    expect(await memory, '42');

    expect(await conns, snapshot);
    expect(h.callbackCompleterMap, isEmpty);

    // data 直接是对象的大包（getProxies 自己另有快路径：原始字符串整包交给调用方，见 groups_snapshot_test，这里换一种回包测）
    final proxies = h.invoke<Map>(method: ActionMethod.getExternalProviders, timeout: const Duration(seconds: 5));
    final table = {for (var i = 0; i < 600; i++) '节点 $i': {'name': '节点 $i', 'type': 'Vless', 'history': <Object>[], 'alive': true, 'udp': true}};
    final bigMap = _reply(h.lastId, 'getExternalProviders', table);
    expect(bigMap.length, greaterThan(offMainDecodeThreshold));
    h.handleMessage(bigMap);
    final got = await proxies;
    expect(got, hasLength(600));
    expect((got['节点 7'] as Map)['type'], 'Vless');
    expect(h.callbackCompleterMap, isEmpty);
  });

  group('request 推送', () {
    late _Handler h;
    late List<String> seen;
    late StreamSubscription<Map<String, Object?>> sub;

    setUp(() {
      h = _Handler();
      seen = [];
      sub = clashMessage.controller.stream.listen((m) {
        final data = m['data'];
        seen.add('${m['type']}:${data is Map ? data['id'] : data}');
      });
    });

    tearDown(() async {
      clashMessage.clearPendingRequests();
      await sub.cancel();
    });

    test('没人看请求页：只留原文不解码；打开时按到达顺序补上，之后逐条处理；关掉后恢复只留原文', () async {
      h.handleMessage(_push('request', _connJson(1)));
      h.handleMessage(_push('request', _connJson(2)));
      // 别的推送不受影响
      h.handleMessage(_push('loaded', 'provider-a'));
      await pumpEventQueue();
      expect(seen, ['loaded:provider-a']);

      clashMessage.watchRequests();
      await pumpEventQueue();
      expect(seen, ['loaded:provider-a', 'request:c1', 'request:c2']);

      h.handleMessage(_push('request', _connJson(3)));
      await pumpEventQueue();
      expect(seen.last, 'request:c3');

      clashMessage.unwatchRequests();
      h.handleMessage(_push('request', _connJson(4)));
      await pumpEventQueue();
      expect(seen, hasLength(4));

      // 换配置清空请求列表时，没解的那些一并丢掉
      clashMessage.clearPendingRequests();
      clashMessage.watchRequests();
      await pumpEventQueue();
      expect(seen, hasLength(4));
      clashMessage.unwatchRequests();
    });

    test('留的原文与请求列表同样封顶 $maxLength 条，顶掉最早的', () async {
      for (var i = 0; i < maxLength + 5; i++) {
        h.handleMessage(_push('request', _connJson(i)));
      }
      clashMessage.watchRequests();
      await pumpEventQueue();
      clashMessage.unwatchRequests();
      expect(seen, hasLength(maxLength));
      expect(seen.first, 'request:c5');
      expect(seen.last, 'request:c${maxLength + 4}');
    });

    test('信封字段顺序对不上前缀（核心改了结构体）：退回逐条解码，不丢', () async {
      h.handleMessage(json.encode({'method': 'message', 'id': '', 'data': {'type': 'request', 'data': _connJson(9)}, 'code': 0}));
      await pumpEventQueue();
      expect(seen, ['request:c9']);
    });
  });
}
