import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/meowx/state/speed_board.dart';
import 'package:bett_box/meowx/state/speed_test.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/haptics.dart';

const _client = SpeedBoardClientInfo(platform: 'android', version: '0.4.5');
const _installId = '3f0c2b8e-4d1a-4c6e-9b7f-2a5d8e1c4b90';
const _hkt = SpeedTestExit(ip: '203.0.113.8', asn: 4760, org: 'Hong Kong Telecommunications (HKT) Limited', country: 'HK');

SpeedTestRecord _record({
  String id = 'r1',
  SpeedTestSource source = SpeedTestSource.apple,
  int connections = 8,
  String outbound = '🇭🇰 香港 IEPL 01',
  String? protocol = 'VLESS',
  String? protocolCode = 'vless',
  String? network = '5G',
  int? durationMs = 20500,
  String? error,
  SpeedBoardEntry? board,
  SpeedTestExit? exit = _hkt,
}) => SpeedTestRecord(
  id: id,
  date: DateTime.utc(2026, 10, 29, 15, 42, 10).toLocal(),
  source: source,
  connections: connections,
  outbound: outbound,
  via: outbound,
  server: 'mensura.cdn-apple.com',
  latencyMs: error == null ? 38 : null,
  downloadMbps: error == null ? 486.234 : null,
  uploadMbps: error == null && source.hasUpload ? 92.7 : null,
  downloadPeakMbps: error == null ? 533.0 : null,
  uploadPeakMbps: error == null && source.hasUpload ? 101.4 : null,
  downloadSamples: error == null ? const [12.1, 210.4, 480.0, 491.123] : const [],
  uploadSamples: error == null && source.hasUpload ? const [80, 92.5, 93.1] : const [],
  bytesUsed: 746586112,
  error: error,
  exit: exit,
  network: network,
  protocol: protocol,
  protocolCode: protocolCode,
  durationMs: durationMs,
  board: board,
);

const _okBody = '{"id":"No63xGk","url":"https://speed.meowx.net/r/No63xGk","delete_token":"V496tok",'
    '"percentile":{"value":88,"scope":"近 30 天 · 经节点 · 多线程","samples":2431},'
    '"provider":{"id":1,"name":"咕咕云"},"asn":4760,"org":"HKT","country":"HK","city":"Hong Kong","attributed":true}';

String _resp(int status, {String body = '', String? retryAfter, String? error, bool noProxy = false}) => json.encode({
  'status': status,
  if (body.isNotEmpty) 'body': body,
  'retryAfter': ?retryAfter,
  'error': ?error,
  if (noProxy) 'noProxy': true,
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('取值（规格 §2）', () {
    test('协议码：mihomo 的写法、配置里的写法、旧记录的显示名都换成小写规格码', () {
      expect(speedBoardProtocolCode('Vless'), 'vless');
      expect(speedBoardProtocolCode('Vmess'), 'vmess');
      expect(speedBoardProtocolCode('Shadowsocks'), 'ss');
      expect(speedBoardProtocolCode('ShadowsocksR'), 'ssr');
      expect(speedBoardProtocolCode('Socks5'), 'socks5');
      expect(speedBoardProtocolCode('Http'), 'http');
      expect(speedBoardProtocolCode('Hysteria2'), 'hysteria2');
      expect(speedBoardProtocolCode('Tuic'), 'tuic');
      expect(speedBoardProtocolCode('AnyTLS'), 'anytls');
      expect(speedBoardProtocolCode('WireGuard'), 'wireguard');
      expect(speedBoardProtocolCode('Miu'), 'miu');
      expect(speedBoardProtocolCode('Snell'), 'snell');
      expect(speedBoardProtocolCode('ss'), 'ss');
      // 旧记录只有显示名（speedTestProtocolTitle 的结果）
      for (final type in ['ss', 'vless', 'vmess', 'trojan', 'hysteria2', 'tuic', 'anytls', 'socks5', 'wireguard', 'mieru']) {
        expect(speedBoardProtocolCode(speedTestProtocolTitle(type)), type, reason: type);
      }
      expect(speedBoardProtocolCode(null), isNull);
      expect(speedBoardProtocolCode('  '), isNull);
      expect(speedBoardProtocolCode('Trust Tunnel!'), 'trusttunnel'); // 规格外的字符去掉
      expect(speedBoardProtocolCode('！！'), isNull);
    });

    test('网络码：Wi-Fi / 5G … / 移动数据 / 有线网络；取不到 null', () {
      expect(
        ['Wi-Fi', '5G', '4G', '3G', '2G', '移动数据', '有线网络', null, '别的'].map(speedBoardNetworkCode).toList(),
        ['wifi', '5g', '4g', '3g', '2g', 'cellular', 'wired', null, null],
      );
    });

    test('install_id 是小写 UUID v4，每次不同', () {
      final pattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      final a = newSpeedBoardInstallId(), b = newSpeedBoardInstallId();
      expect(a, matches(pattern));
      expect(b, matches(pattern));
      expect(a, isNot(b));
      expect(newSpeedBoardInstallId(Random(1)), newSpeedBoardInstallId(Random(1)));
    });

    test('finished_at：UTC、RFC3339 到秒', () {
      expect(speedBoardTime(DateTime.utc(2026, 1, 2, 3, 4, 5, 678)), '2026-01-02T03:04:05Z');
      expect(speedBoardTime(DateTime.utc(2026, 10, 29, 15, 42, 10).toLocal()), '2026-10-29T15:42:10Z');
    });
  });

  group('上传正文（规格 §3）', () {
    Map<String, Object?> testPart(Map<String, Object?> body) => body['test']! as Map<String, Object?>;

    test('经节点、测上传的源：字段齐全、snake_case，协议用规格码，数值保留两位', () {
      final body = speedBoardBody(_record(), installId: _installId, client: _client);
      expect(body['v'], 1);
      expect(body['client'], {'app': 'MeowX', 'platform': 'android', 'version': '0.4.5', 'install_id': _installId});
      expect(testPart(body), {
        'source': 'apple',
        'connections': 8,
        'mode': 'node',
        'protocol': 'vless',
        'network': '5g',
        'latency_ms': 38,
        'download_mbps': 486.23,
        'upload_mbps': 92.7,
        'download_peak_mbps': 533.0,
        'upload_peak_mbps': 101.4,
        'download_samples': [12.1, 210.4, 480.0, 491.12],
        'upload_samples': [80.0, 92.5, 93.1],
        'bytes_used': 746586112,
        'duration_ms': 20500,
        'server': 'mensura.cdn-apple.com',
        'finished_at': '2026-10-29T15:42:10Z',
      });
      expect(body['claimed_exit'], {'asn': 4760, 'org': 'Hong Kong Telecommunications (HKT) Limited', 'country': 'HK'});
    });

    test('不传节点名、IP', () {
      final text = json.encode(speedBoardBody(_record(), installId: _installId, client: _client));
      expect(text, isNot(contains('香港 IEPL')));
      expect(text, isNot(contains('203.0.113.8')));
      expect(text.length, lessThan(16 * 1024));
    });

    test('只测下载的源（Google / Microsoft）：upload 为 null、upload_samples 为空；时长没记的按每段 10 秒 + 1.5 秒估', () {
      for (final source in [SpeedTestSource.google, SpeedTestSource.microsoft]) {
        final t = testPart(speedBoardBody(_record(source: source, durationMs: null), installId: _installId, client: _client));
        expect(t.containsKey('upload_mbps'), isTrue);
        expect(t['upload_mbps'], isNull);
        expect(t['upload_peak_mbps'], isNull);
        expect(t['upload_samples'], isEmpty);
        expect(t['duration_ms'], 11500);
      }
      expect(testPart(speedBoardBody(_record(durationMs: null), installId: _installId, client: _client))['duration_ms'], 21500);
    });

    test('直连：mode = direct、没有协议；没查到出口 claimed_exit 为 null；没取到网络 network 为 null', () {
      final body = speedBoardBody(
        _record(outbound: kSpeedTestDirect, protocol: null, protocolCode: null, exit: null, network: null),
        installId: _installId,
        client: _client,
      );
      expect(testPart(body)['mode'], 'direct');
      expect(testPart(body)['protocol'], isNull);
      expect(testPart(body)['network'], isNull);
      expect(body.containsKey('claimed_exit'), isTrue);
      expect(body['claimed_exit'], isNull);
    });

    test('旧记录只有协议显示名：按显示名换回规格码；什么都没有的节点记录不能上传', () {
      final old = _record(protocol: 'Shadowsocks', protocolCode: null);
      expect(old.boardProtocol, 'ss');
      expect(testPart(speedBoardBody(old, installId: _installId, client: _client))['protocol'], 'ss');
      expect(speedBoardBlocker(old), isNull);
      expect(speedBoardBlocker(_record(protocol: null, protocolCode: null)), isNotNull);
      expect(speedBoardBlocker(_record(outbound: kSpeedTestDirect, protocol: null, protocolCode: null)), isNull);
      expect(speedBoardBlocker(_record(error: '连接超时')), isNotNull);
    });

    test('正文字节编一次就定下来：同一条记录字节、hash 都一样；hash 是 sha256 的 64 位小写 hex', () {
      final a = speedBoardBytes(speedBoardBody(_record(), installId: _installId, client: _client));
      final b = speedBoardBytes(speedBoardBody(_record(), installId: _installId, client: _client));
      expect(a, b);
      final hash = speedBoardHash(a);
      expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(hash, sha256.convert(a).toString());
      expect(speedBoardHash(speedBoardBytes(speedBoardBody(_record(), installId: newSpeedBoardInstallId(), client: _client))),
          isNot(hash));
      // 字节就是 UTF-8 的 JSON
      expect(json.decode(utf8.decode(a)), speedBoardBody(_record(), installId: _installId, client: _client));
    });
  });

  group('应答（规格 §5.2 / §5.2.1）', () {
    final now = DateTime(2026, 10, 30, 12);

    test('核心回的 JSON：旧核心（null / 空）与认不出的都当没回', () {
      expect(SpeedBoardHttp.parse(null), isNull);
      expect(SpeedBoardHttp.parse(''), isNull);
      expect(SpeedBoardHttp.parse('不是 JSON'), isNull);
      final r = SpeedBoardHttp.parse(_resp(429, body: '{"code":"rate_limited"}', retryAfter: '600'))!;
      expect((r.status, r.retryAfter, r.code), (429, '600', 'rate_limited'));
      expect(SpeedBoardHttp.parse(_resp(0, error: 'x', noProxy: true))!.noProxy, isTrue);
    });

    test('200：链接、删除凭据、超越比例、服务商、走了凭证', () {
      final e = speedBoardUploadOutcome(SpeedBoardHttp.parse(_resp(200, body: _okBody)), attributed: false);
      expect(e.isUploaded, isTrue);
      expect((e.id, e.url, e.deleteToken), ('No63xGk', 'https://speed.meowx.net/r/No63xGk', 'V496tok'));
      expect(e.shortUrl, 'speed.meowx.net/r/No63xGk');
      expect(e.percentile, const SpeedBoardPercentile(value: 88, scope: '近 30 天 · 经节点 · 多线程', samples: 2431));
      expect(e.percentile!.scopeLine, '近 30 天 · 经节点 · 多线程 · 2,431 次');
      expect(e.provider, '咕咕云');
      expect(e.attributed, isTrue);
    });

    test('200：样本不够 percentile 为 null、认不出服务商 provider 为 null；缺 id / url 算失败', () {
      final e = speedBoardUploadOutcome(
        SpeedBoardHttp.parse(_resp(200, body: '{"id":"a","url":"https://x/r/a","delete_token":"t","percentile":null,"provider":null}')),
        attributed: true,
      );
      expect(e.isUploaded, isTrue);
      expect(e.percentile, isNull);
      expect(e.provider, isNull);
      expect(e.attributed, isTrue); // 应答没带 attributed 时按有没有凭证
      final bad = speedBoardUploadOutcome(SpeedBoardHttp.parse(_resp(200, body: '{"url":"x"}')), attributed: false);
      expect(bad.isFailed, isTrue);
      expect(bad.retryable, isTrue);
    });

    test('400 不重试；429 按 Retry-After 延后；5xx / 连不上 / 找不到出站 / 旧核心可重试', () {
      final rejected = speedBoardUploadOutcome(SpeedBoardHttp.parse(_resp(400, body: '{"code":"bad_request"}')), attributed: false);
      expect((rejected.isFailed, rejected.retryable), (true, false));

      final limited = speedBoardUploadOutcome(SpeedBoardHttp.parse(_resp(429, retryAfter: '600')), attributed: false, now: now);
      expect((limited.isFailed, limited.retryable), (true, true));
      expect(limited.retryAt, now.add(const Duration(minutes: 10)));
      expect(limited.waitBeforeRetry(now.add(const Duration(minutes: 9))), const Duration(minutes: 1));
      expect(limited.waitBeforeRetry(now.add(const Duration(minutes: 10))), isNull);

      for (final raw in [_resp(500), _resp(502), _resp(0, error: 'connection refused'), _resp(0, noProxy: true), _resp(403), null]) {
        final e = speedBoardUploadOutcome(SpeedBoardHttp.parse(raw), attributed: false);
        expect((e.isFailed, e.retryable, e.error != null), (true, true, true), reason: raw);
      }
      expect(speedBoardUploadOutcome(null, attributed: false).error, contains('内核版本过旧'));
    });

    test('Retry-After：秒数、HTTP 日期；认不出 / 没有给 10 分钟', () {
      expect(speedBoardRetryAfter('120'), const Duration(minutes: 2));
      expect(
        speedBoardRetryAfter('Fri, 30 Oct 2026 12:05:00 GMT', now: DateTime.utc(2026, 10, 30, 12)),
        const Duration(minutes: 5),
      );
      expect(speedBoardRetryAfter(null), const Duration(minutes: 10));
      expect(speedBoardRetryAfter('明天'), const Duration(minutes: 10));
    });

    test('删除：200（含已删过）/ 404 都算删掉了；403 删除凭据不对；连不上 / 旧核心失败', () {
      expect(speedBoardDeleteOutcome(SpeedBoardHttp.parse(_resp(200, body: '{"success":true}'))), isA<SpeedBoardDeleted>());
      expect(speedBoardDeleteOutcome(SpeedBoardHttp.parse(_resp(404, body: '{"code":"not_found"}'))), isA<SpeedBoardDeleted>());
      expect(
        (speedBoardDeleteOutcome(SpeedBoardHttp.parse(_resp(403, body: '{"code":"forbidden"}'))) as SpeedBoardDeleteFailed).message,
        '删除凭据不对',
      );
      expect(speedBoardDeleteOutcome(SpeedBoardHttp.parse(_resp(0, error: 'x'))), isA<SpeedBoardDeleteFailed>());
      expect(speedBoardDeleteOutcome(null), isA<SpeedBoardDeleteFailed>());
    });
  });

  group('上传器', () {
    /// 记下发给核心的每个请求，按顺序回 [responses]
    ({SpeedBoardUploader uploader, List<Map<String, Object?>> sent}) fake(
      List<String?> responses, {
      SpeedBoardGrant? grant,
      SpeedBoardEndpoint endpoint = const SpeedBoardEndpoint(),
    }) {
      final sent = <Map<String, Object?>>[];
      final uploader = SpeedBoardUploader(
        send: (data) async {
          sent.add(json.decode(data) as Map<String, Object?>);
          return responses.removeAt(0);
        },
        grant: grant,
        endpoint: endpoint,
      );
      return (uploader: uploader, sent: sent);
    }

    List<int> bodyOf(Map<String, Object?> req) => base64.decode(req['body']! as String);
    Map<String, Object?> headersOf(Map<String, Object?> req) => req['headers']! as Map<String, Object?>;

    test('匿名：经测速用的出站 POST 到正式地址，Content-Type 是 JSON，不带凭证', () async {
      final f = fake([_resp(200, body: _okBody)]);
      final e = await f.uploader.upload(_record(), installId: _installId, client: _client);
      expect(e.isUploaded, isTrue);
      final req = f.sent.single;
      expect(req['proxy'], '🇭🇰 香港 IEPL 01');
      expect(req['method'], 'POST');
      expect(req['url'], 'https://license.miaomiaowux.com/api/v2/speedtest/results');
      expect(headersOf(req), {'Content-Type': 'application/json'});
    });

    test('有凭证：申请凭证的 hash 就是发出去的正文字节的 sha256，头带 X-MeowX-Speed-Grant', () async {
      String? askedHash;
      final f = fake([_resp(200, body: _okBody)], grant: (hash) async {
        askedHash = hash;
        return 'claims.sig';
      });
      await f.uploader.upload(_record(), installId: _installId, client: _client);
      final req = f.sent.single;
      expect(headersOf(req)['X-MeowX-Speed-Grant'], 'claims.sig');
      expect(askedHash, sha256.convert(bodyOf(req)).toString());
    });

    test('401：去掉凭证、同一份字节匿名再传一次；没带凭证的 401 不重传', () async {
      final f = fake([_resp(401, body: '{"code":"grant_used"}'), _resp(200, body: _okBody.replaceFirst('"attributed":true', '"attributed":false'))],
          grant: (_) async => 'g');
      final e = await f.uploader.upload(_record(), installId: _installId, client: _client);
      expect(f.sent, hasLength(2));
      expect(headersOf(f.sent[0]).containsKey('X-MeowX-Speed-Grant'), isTrue);
      expect(headersOf(f.sent[1]).containsKey('X-MeowX-Speed-Grant'), isFalse);
      expect(bodyOf(f.sent[1]), bodyOf(f.sent[0]));
      expect((e.isUploaded, e.attributed), (true, false));

      final anon = fake([_resp(401)]);
      final failed = await anon.uploader.upload(_record(), installId: _installId, client: _client);
      expect(anon.sent, hasLength(1));
      expect(failed.isFailed, isTrue);
    });

    test('申请凭证出错 / 超时：照样匿名传', () async {
      final f = fake([_resp(200, body: _okBody)], grant: (_) async => throw Exception('主控连不上'));
      expect((await f.uploader.upload(_record(), installId: _installId, client: _client)).isUploaded, isTrue);
      expect(headersOf(f.sent.single).containsKey('X-MeowX-Speed-Grant'), isFalse);

      final slow = fake([_resp(200, body: _okBody)], grant: (_) => Completer<String?>().future);
      final started = DateTime.now();
      await slow.uploader.upload(_record(), installId: _installId, client: _client);
      expect(DateTime.now().difference(started), lessThan(SpeedBoardUploader.grantTimeout + const Duration(seconds: 2)));
      expect(headersOf(slow.sent.single).containsKey('X-MeowX-Speed-Grant'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('联调地址：http 只在这时允许，上传强制 DIRECT，带 CF-Connecting-IP', () async {
      final endpoint = SpeedBoardEndpoint.fromEnvironment(api: 'http://localhost:12890/', cfIp: '1.1.1.9');
      expect((endpoint.override, endpoint.base, endpoint.connectingIp), (true, 'http://localhost:12890', '1.1.1.9'));
      expect(endpoint.boardPage, 'http://localhost:12890/board');
      final f = fake([_resp(200, body: _okBody)], endpoint: endpoint);
      await f.uploader.upload(_record(), installId: _installId, client: _client);
      expect(f.sent.single['proxy'], kSpeedTestDirect);
      expect(f.sent.single['url'], 'http://localhost:12890/api/v2/speedtest/results');
      expect(headersOf(f.sent.single)['CF-Connecting-IP'], '1.1.1.9');

      // 没设 / 设的不是 http(s)：正式地址，只认 https
      for (final api in ['', 'ftp://x', '不是地址']) {
        final e = SpeedBoardEndpoint.fromEnvironment(api: api);
        expect((e.override, e.base, e.boardPage), (false, kSpeedBoardApi, kSpeedBoardPage));
      }
      const plain = SpeedBoardEndpoint(base: 'http://license.miaomiaowux.com');
      final rejected = fake([]);
      final e = await SpeedBoardUploader(send: rejected.uploader.send, endpoint: plain).upload(_record(), installId: _installId, client: _client);
      expect((e.isFailed, e.retryable), (true, false));
      expect(rejected.sent, isEmpty);
    });

    test('不能传的记录（失败的、没有协议的节点记录）不发请求', () async {
      final f = fake([]);
      expect((await f.uploader.upload(_record(error: '超时'), installId: _installId, client: _client)).retryable, isFalse);
      expect((await f.uploader.upload(_record(protocol: null, protocolCode: null), installId: _installId, client: _client)).retryable,
          isFalse);
      expect(f.sent, isEmpty);
    });

    test('删除：经测速用的出站 DELETE，带删除凭据；出站不在了换 DIRECT', () async {
      const uploaded = SpeedBoardEntry(status: SpeedBoardStatus.uploaded, id: 'No63xGk', url: 'https://speed.meowx.net/r/No63xGk', deleteToken: 'tok');
      final f = fake([_resp(0, noProxy: true), _resp(200, body: '{"success":true}')]);
      final result = await f.uploader.delete(_record(board: uploaded));
      expect(result, isA<SpeedBoardDeleted>());
      expect(f.sent.map((r) => r['proxy']), ['🇭🇰 香港 IEPL 01', kSpeedTestDirect]);
      expect(f.sent.first['method'], 'DELETE');
      expect(f.sent.first['url'], 'https://license.miaomiaowux.com/api/v2/speedtest/results/No63xGk');
      expect(headersOf(f.sent.first), {'X-MeowX-Delete-Token': 'tok'});
      expect(f.sent.first.containsKey('body'), isFalse);
    });
  });

  group('记录里的测速榜字段', () {
    test('新旧记录 JSON 都读得回：旧记录没有这几项 = 没传过；新记录原样往返', () {
      final old = SpeedTestRecord.fromJson(const {
        'id': 'a',
        'date': 1761752530,
        'source': 'apple',
        'connections': 8,
        'outbound': '香港 01',
        'downloadMbps': 100,
        'protocol': 'VLESS',
      })!;
      expect(old.board, isNull);
      expect(old.durationMs, isNull);
      expect(old.protocolCode, isNull);
      expect(old.boardProtocol, 'vless');

      final entry = SpeedBoardEntry(
        status: SpeedBoardStatus.uploaded,
        id: 'No63xGk',
        url: 'https://speed.meowx.net/r/No63xGk',
        deleteToken: 'tok',
        percentile: const SpeedBoardPercentile(value: 82, scope: '近 30 天 · 经节点 · 多线程', samples: 2431),
        provider: '咕咕云',
        attributed: true,
      );
      final record = _record(board: entry);
      final back = SpeedTestRecord.fromJson(json.decode(json.encode(record.toJson())) as Map<String, Object?>)!;
      expect(back.board, entry);
      expect(back.protocolCode, 'vless');
      expect(back.durationMs, 20500);
      expect(back.withBoard(null).board, isNull);
      expect(back.withBoard(null).downloadMbps, record.downloadMbps);

      final limited = SpeedBoardEntry.failure('上传太频繁', retryAt: DateTime.fromMillisecondsSinceEpoch(1761800000000));
      expect(SpeedBoardEntry.fromJson(json.decode(json.encode(limited.toJson()))), limited);
      final rejected = SpeedBoardEntry.failure('不收', retryable: false);
      expect(SpeedBoardEntry.fromJson(json.decode(json.encode(rejected.toJson())))!.retryable, isFalse);
    });

    test('存盘时还在上传（App 被关了）：读回来是可重试的失败；认不出的状态当没传过', () {
      final e = SpeedBoardEntry.fromJson(SpeedBoardEntry.uploading.toJson())!;
      expect((e.isFailed, e.retryable), (true, true));
      expect(SpeedBoardEntry.fromJson(const {'status': 'what'}), isNull);
      expect(SpeedBoardEntry.fromJson(const {'status': 'uploaded'}), isNull); // 没有 id / url
      expect(SpeedBoardEntry.fromJson('x'), isNull);
    });
  });

  group('控制器', () {
    setUp(recordHaptics);

    const done = '{"runID":1,"phase":"done","source":"apple","via":"香港 01","server":"mensura.cdn-apple.com","latencyMs":38,'
        '"downloadMbps":486.4,"downloadPeakMbps":533,"uploadMbps":92.7,"uploadPeakMbps":101,"downloadSamples":[100,480],'
        '"uploadSamples":[90,92],"bytesUsed":746586112,"durationMs":20480}';

    ({SpeedTestController c, List<Map<String, Object?>> board}) make({
      String status = done,
      List<String?> boardResponses = const [],
    }) {
      final board = <Map<String, Object?>>[];
      final responses = [...boardResponses];
      final c = SpeedTestController(
        clientInfo: () => _client,
        boardEndpoint: const SpeedBoardEndpoint(),
        networkProbe: () async => 'Wi-Fi',
        call: (method, data) async {
          switch (method) {
            case ActionMethod.meowSpeedTestStatus:
              return status;
            case ActionMethod.meowSpeedTestBoard:
              board.add(json.decode(data) as Map<String, Object?>);
              return responses.isEmpty ? null : responses.removeAt(0);
            default:
              return '';
          }
        },
      );
      return (c: c, board: board);
    }

    test('同意过：测完自动上传，记录先「上传中」、传完换成结果；正文带核心给的时长与协议码', () async {
      SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': true});
      final m = make(boardResponses: [_resp(200, body: _okBody)]);
      await m.c.load();
      expect(m.c.boardConsent, isTrue);
      final states = <SpeedBoardStatus?>[];
      m.c.history.addListener(() => states.add(m.c.history.records.firstOrNull?.board?.status));
      await m.c.start('香港 01', protocol: 'VLESS', protocolCode: 'vless');
      await pumpEventQueue();
      final record = m.c.history.records.single;
      expect(record.durationMs, 20480);
      expect(record.protocolCode, 'vless');
      expect(record.board!.isUploaded, isTrue);
      expect(record.board!.percentile!.value, 88);
      expect(states, containsAllInOrder([null, SpeedBoardStatus.uploading, SpeedBoardStatus.uploaded]));
      final body = json.decode(utf8.decode(base64.decode(m.board.single['body']! as String))) as Map<String, Object?>;
      final t = body['test']! as Map<String, Object?>;
      expect((t['duration_ms'], t['protocol'], t['network'], t['mode']), (20480, 'vless', 'wifi', 'node'));
      // install_id 生成一次、存下来，之后都用它
      final id = (body['client']! as Map)['install_id'];
      expect((await SharedPreferences.getInstance()).getString('meowx.speedTest.installId'), id);
    });

    test('没问过 / 不同意：不上传；失败的测速不上传', () async {
      for (final consent in [null, false]) {
        SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': ?consent});
        final m = make();
        await m.c.load();
        expect(m.c.boardConsent, consent);
        await m.c.start('香港 01', protocol: 'VLESS', protocolCode: 'vless');
        await pumpEventQueue();
        expect(m.board, isEmpty);
        expect(m.c.history.records.single.board, isNull);
      }
      SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': true});
      final failed = make(status: '{"runID":1,"phase":"failed","error":"连不上"}');
      await failed.c.load();
      await failed.c.start('香港 01', protocol: 'VLESS', protocolCode: 'vless');
      await pumpEventQueue();
      expect(failed.board, isEmpty);
    });

    test('上传失败留在记录里，重试重新组正文、重新要凭证；从测速榜删除只清远端字段、本机记录还在', () async {
      SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': true});
      var grants = 0;
      final m = make(boardResponses: [_resp(503), _resp(200, body: _okBody), _resp(200, body: '{"success":true}')]);
      m.c.board.grant = (_) async {
        grants++;
        return 'g$grants';
      };
      await m.c.load();
      await m.c.start('香港 01', protocol: 'VLESS', protocolCode: 'vless');
      await pumpEventQueue();
      final id = m.c.history.records.single.id;
      expect(m.c.history.byId(id)!.board!.isFailed, isTrue);
      await m.c.uploadToBoard(id);
      expect(m.c.history.byId(id)!.board!.isUploaded, isTrue);
      expect(grants, 2);
      expect((m.board[1]['headers']! as Map)['X-MeowX-Speed-Grant'], 'g2');

      expect(await m.c.deleteFromBoard(id), isNull);
      final after = m.c.history.byId(id)!;
      expect(after.board, isNull);
      expect(after.downloadMbps, 486.4);
      expect(m.board.last['method'], 'DELETE');
    });

    test('删除失败回原因、远端字段保留', () async {
      SharedPreferences.setMockInitialValues({'meowx.speedTest.upload': true});
      final m = make(boardResponses: [_resp(200, body: _okBody), _resp(403, body: '{"code":"forbidden"}')]);
      await m.c.load();
      await m.c.start('香港 01', protocol: 'VLESS', protocolCode: 'vless');
      await pumpEventQueue();
      final id = m.c.history.records.single.id;
      expect(await m.c.deleteFromBoard(id), '删除凭据不对');
      expect(m.c.history.byId(id)!.board!.isUploaded, isTrue);
    });

    test('设置同意、重置身份都存本机偏好；重置后换一个新的 install_id', () async {
      final m = make();
      await m.c.load();
      expect(m.c.prefsLoaded, isTrue);
      m.c.setBoardConsent(true);
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('meowx.speedTest.upload'), isTrue);
      await m.c.resetBoardIdentity();
      final first = prefs.getString('meowx.speedTest.installId');
      await m.c.resetBoardIdentity();
      expect(prefs.getString('meowx.speedTest.installId'), isNot(first));
    });
  });
}
