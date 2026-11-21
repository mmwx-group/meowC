import 'dart:io';

import 'package:bett_box/meowx/net/subscription_fetch.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 拉订阅换路重试（2026-11-20，Windows 用户导入订阅报握手被中断）。
void main() {
  final uri = Uri.parse('https://sub.example/x/SECRETTOKEN?t=auto');
  RequestOptions ro() => RequestOptions(path: uri.toString());
  DioException handshake() => DioException(
    requestOptions: ro(),
    error: const HandshakeException('Connection terminated during handshake'),
  );
  DioException status(int code) => DioException.badResponse(
    statusCode: code,
    requestOptions: ro(),
    response: Response(requestOptions: ro(), statusCode: code),
  );
  Response<dynamic> ok(String body) => Response(requestOptions: ro(), statusCode: 200, data: body);
  InternetAddress ip(String s) => InternetAddress(s);

  group('重不重试（只看连接层）', () {
    test('握手被掐 / 连不上 / 连接超时 / 读超时 / 连接被重置：重试', () {
      expect(SubFetchPolicy.shouldRetry(handshake()), isTrue);
      expect(SubFetchPolicy.shouldRetry(DioException.connectionError(requestOptions: ro(), reason: 'x')), isTrue);
      expect(SubFetchPolicy.shouldRetry(DioException.connectionTimeout(requestOptions: ro(), timeout: Duration.zero)), isTrue);
      expect(SubFetchPolicy.shouldRetry(DioException.receiveTimeout(requestOptions: ro(), timeout: Duration.zero)), isTrue);
      expect(
        SubFetchPolicy.shouldRetry(DioException(requestOptions: ro(), error: const SocketException('Connection reset by peer'))),
        isTrue,
      );
      expect(SubFetchPolicy.shouldRetry(const SocketException('x')), isTrue);
      expect(SubFetchPolicy.shouldRetry(const HttpException('Connection closed before full header was received')), isTrue);
    });

    test('拿到了 HTTP 状态码、证书不对、用户取消、别的错误：不重试', () {
      expect(SubFetchPolicy.shouldRetry(status(404)), isFalse);
      expect(SubFetchPolicy.shouldRetry(status(502)), isFalse);
      expect(SubFetchPolicy.shouldRetry(DioException.badCertificate(requestOptions: ro())), isFalse);
      expect(SubFetchPolicy.shouldRetry(DioException.requestCancelled(requestOptions: ro(), reason: null)), isFalse);
      expect(SubFetchPolicy.shouldRetry(const FormatException('x')), isFalse);
      expect(SubFetchPolicy.shouldRetry(DioException(requestOptions: ro(), error: const FormatException('x'))), isFalse);
    });

    test('失败类型', () {
      expect(SubFetchPolicy.kindOf(handshake()), SubFetchFailureKind.handshake);
      expect(
        SubFetchPolicy.kindOf(const SocketException('read failed', osError: OSError('Connection reset by peer', 54))),
        SubFetchFailureKind.reset,
      );
      expect(SubFetchPolicy.kindOf(const SocketException('Failed host lookup: sub.example')), SubFetchFailureKind.dns);
      expect(
        SubFetchPolicy.kindOf(const SocketException('x', osError: OSError('Connection refused', 111))),
        SubFetchFailureKind.refused,
      );
      expect(
        SubFetchPolicy.kindOf(DioException.connectionTimeout(requestOptions: ro(), timeout: Duration.zero)),
        SubFetchFailureKind.timeout,
      );
    });
  });

  group('顺序、跳过、时限', () {
    test('内核起着：经本机代理 → 直连 → 换 DNS 解析；没起：直连 → 换 DNS 解析', () {
      expect(SubFetchPolicy.routes(coreRunning: true), [
        SubFetchRoute.viaCore,
        SubFetchRoute.direct,
        SubFetchRoute.resolvedIp,
      ]);
      expect(SubFetchPolicy.routes(coreRunning: false), [SubFetchRoute.direct, SubFetchRoute.resolvedIp]);
    });

    test('加密 DNS 的结果全在本机结果里 = 跳过；只留新的、去重、至多两个', () {
      expect(SubFetchPolicy.freshAddresses([ip('1.1.1.1'), ip('2.2.2.2')], [ip('2.2.2.2'), ip('1.1.1.1')]), isEmpty);
      expect(
        SubFetchPolicy.freshAddresses([ip('1.1.1.1')], [ip('1.1.1.1'), ip('3.3.3.3'), ip('3.3.3.3'), ip('4.4.4.4'), ip('5.5.5.5')])
            .map((a) => a.address),
        ['3.3.3.3', '4.4.4.4'],
      );
      expect(SubFetchPolicy.freshAddresses(const [], [ip('6.6.6.6')]).map((a) => a.address), ['6.6.6.6']);
    });

    test('连接超时：第一条用自己的上限，之后取上限与剩余时间的较小者，剩不到 2 秒不试', () {
      expect(SubFetchPolicy.connectTimeout(SubFetchRoute.viaCore, first: true, remaining: Duration.zero), const Duration(seconds: 12));
      expect(
        SubFetchPolicy.connectTimeout(SubFetchRoute.direct, first: false, remaining: const Duration(seconds: 20)),
        const Duration(seconds: 10),
      );
      expect(
        SubFetchPolicy.connectTimeout(SubFetchRoute.direct, first: false, remaining: const Duration(seconds: 5)),
        const Duration(seconds: 5),
      );
      expect(SubFetchPolicy.connectTimeout(SubFetchRoute.resolvedIp, first: false, remaining: const Duration(milliseconds: 1500)), isNull);
    });

    test('给人看的话：说清是哪种失败、试了哪几条路；只有一条路时不说「都」', () {
      final f = [
        SubFetchFailure(route: SubFetchRoute.viaCore, host: 'sub.example', error: handshake()),
        SubFetchFailure(route: SubFetchRoute.direct, host: 'sub.example', error: handshake()),
        SubFetchFailure(route: SubFetchRoute.resolvedIp, host: 'sub.example', ip: ip('9.9.9.9'), error: handshake()),
      ];
      expect(
        SubFetchPolicy.summary('sub.example', f),
        '连接订阅地址（sub.example）时握手被中断，已尝试经本机代理 / 直连 / 换 DNS 解析，都没连上。可能是其它代理软件或网络在拦截这个地址，可以先退出其它代理软件再试。',
      );
      expect(SubFetchPolicy.summary('sub.example', f.sublist(1, 2)), contains('已尝试直连，没连上'));
    });

    test('日志里不带订阅地址的路径与 token', () {
      final e = DioException(
        requestOptions: ro(),
        error: HttpException('Connection closed before full header was received', uri: uri),
      );
      final line = SubFetchFailure(route: SubFetchRoute.direct, host: 'sub.example', error: e).describe();
      expect(line, contains('sub.example'));
      expect(line, isNot(contains('SECRETTOKEN')));
      expect(SubFetchPolicy.scrub('see $uri now', 'sub.example'), 'see sub.example now');
    });

    test('DNS JSON：只取 A 记录，Status 不是 0 的不要', () {
      const body =
          '{"Status":0,"Answer":[{"type":5,"data":"cname.example."},{"type":1,"data":"203.0.113.7"},{"type":1,"data":"198.51.100.2"}]}';
      expect(SubscriptionHttp.parseDohJson(body).map((a) => a.address), ['203.0.113.7', '198.51.100.2']);
      expect(SubscriptionHttp.parseDohJson('{"Status":3}'), isEmpty);
      expect(SubscriptionHttp.parseDohJson('not json'), isEmpty);
    });
  });

  group('换路（假网络）', () {
    late List<String> calls;
    late List<Duration> timeouts;
    late List<String> logs;
    setUp(() {
      calls = [];
      timeouts = [];
      logs = [];
    });

    SubscriptionFetcher fetcher(
      Future<Response<dynamic>> Function(SubFetchRoute route, InternetAddress? ip) behave, {
      List<InternetAddress> system = const [],
      List<InternetAddress> doh = const [],
      DateTime Function()? now,
    }) => SubscriptionFetcher(
      attempt: (route, ip, timeout, cancel) {
        calls.add(ip == null ? route.name : '${route.name}:${ip.address}');
        timeouts.add(timeout);
        return behave(route, ip);
      },
      systemLookup: (_) async => system,
      dohLookup: (_, _, _) async => doh,
      now: now,
      log: logs.add,
    );

    test('经本机代理握手被掐 → 直连成功：成功即止，日志记一行走的是哪条路', () async {
      final res = await fetcher(
        (route, _) async => route == SubFetchRoute.viaCore ? throw handshake() : ok('proxies: []'),
      ).fetch(uri, coreRunning: true);
      expect(res.data, 'proxies: []');
      expect(calls, ['viaCore', 'direct']);
      expect(logs.last, contains('订阅换路成功：直连（sub.example）'));
      expect(logs.join('\n'), isNot(contains('SECRETTOKEN')));
    });

    test('第一条拿到 404：不换路，原样抛出', () async {
      await expectLater(
        fetcher((_, _) async => throw status(404)).fetch(uri, coreRunning: true),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'status', 404)),
      );
      expect(calls, ['viaCore']);
    });

    test('加密 DNS 解出新地址：按顺序逐个试，成功即止', () async {
      final res = await fetcher(
        (route, ip) async => route != SubFetchRoute.resolvedIp || ip!.address == '203.0.113.1' ? throw handshake() : ok('ok'),
        system: [ip('192.0.2.9')],
        doh: [ip('192.0.2.9'), ip('203.0.113.1'), ip('203.0.113.2')],
      ).fetch(uri, coreRunning: false);
      expect(res.data, 'ok');
      expect(calls, ['direct', 'resolvedIp:203.0.113.1', 'resolvedIp:203.0.113.2']);
      expect(logs.last, contains('换 DNS 解析（sub.example → 203.0.113.2）'));
    });

    test('加密 DNS 与本机解析一致：跳过这一步；全部失败抛给人看的话', () async {
      await expectLater(
        fetcher((_, _) async => throw handshake(), system: [ip('192.0.2.9')], doh: [ip('192.0.2.9')]).fetch(uri, coreRunning: false),
        throwsA(
          isA<SubscriptionFetchException>().having(
            (e) => e.toString(),
            'message',
            '连接订阅地址（sub.example）时握手被中断，已尝试直连，没连上。可能是其它代理软件或网络在拦截这个地址，可以先退出其它代理软件再试。',
          ),
        ),
      );
      expect(calls, ['direct']);
      expect(logs.any((l) => l.contains('结果与本机一致')), isTrue);
    });

    test('总时限：后面的路只拿剩下的时间，剩不到 2 秒就停', () async {
      var t = DateTime(2026);
      final f = fetcher(
        (route, _) async {
          t = t.add(timeouts.last); // 每条路都耗满自己的超时才失败
          throw DioException.connectionTimeout(requestOptions: ro(), timeout: timeouts.last);
        },
        doh: [ip('203.0.113.1'), ip('203.0.113.2')],
        now: () => t,
      );
      await expectLater(f.fetch(uri, coreRunning: true), throwsA(isA<SubscriptionFetchException>()));
      // 12 + 10 = 22 秒后只剩 3 秒：第一个新地址拿 3 秒，第二个没时间了
      expect(calls, ['viaCore', 'direct', 'resolvedIp:203.0.113.1']);
      expect(timeouts, const [Duration(seconds: 12), Duration(seconds: 10), Duration(seconds: 3)]);
    });

    test('取消：正在试的那条失败也不换路，抛「已取消」', () async {
      final token = CancelToken();
      final f = fetcher((route, _) async {
        token.cancel('用户取消');
        throw handshake();
      });
      await expectLater(
        f.fetch(uri, coreRunning: true, cancel: token),
        throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
      expect(calls, ['viaCore']);
    });

    test('取消：查加密 DNS 时取消，不再按 IP 连', () async {
      final token = CancelToken();
      final f = SubscriptionFetcher(
        attempt: (route, ip, _, _) async {
          calls.add(route.name);
          throw handshake();
        },
        systemLookup: (_) async => const [],
        dohLookup: (_, _, _) async {
          token.cancel();
          return [ip('203.0.113.1')];
        },
      );
      await expectLater(
        f.fetch(uri, coreRunning: false, cancel: token),
        throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
      expect(calls, ['direct']);
    });
  });

  group('真网络（本机假服务器）', () {
    late SecurityContext serverCtx, clientCtx;
    late HttpServer server;
    late ServerSocket killer;
    final logs = <String>[];

    // 测试证书：ca.pem（20 年）签的 cert.pem（sub.test / localhost / 127.0.0.1），**2029-01-28 到期**，到期后重新生成：
    // macOS 拒绝有效期超过 825 天的服务器证书，所以叶子证书只给 800 天、另起一张 CA（重新生成时 CA 一起换，私钥不入库）。
    // openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 7300 \
    //   -subj "/CN=MeowX Test CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
    // openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout key.pem -out leaf.csr -subj "/CN=sub.test"
    // openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out cert.pem -days 800 -extfile <(printf \
    //   "subjectAltName=DNS:sub.test,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n")
    setUpAll(() async {
      const dir = 'test/meowx/fixtures/subfetch';
      serverCtx = SecurityContext()
        ..useCertificateChain('$dir/cert.pem')
        ..usePrivateKey('$dir/key.pem');
      clientCtx = SecurityContext(withTrustedRoots: false)..setTrustedCertificates('$dir/ca.pem');
      server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverCtx);
      server.listen((req) {
        req.response
          ..headers.contentType = ContentType.text
          ..write('proxies: [] # ${req.uri.path}')
          ..close();
      });
      // 假的「本机代理」：答应 CONNECT，紧接着把连接掐掉——客户端的 TLS 握手就被中断（同用户报的 HandshakeException）
      killer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      killer.listen((s) {
        s.listen((_) {
          s.write('HTTP/1.1 200 Connection established\r\n\r\n');
          s.flush().then((_) => s.destroy());
        }, onError: (_) {});
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
      await killer.close();
    });

    setUp(logs.clear);

    SubscriptionFetcher real(String url, {List<InternetAddress> doh = const []}) {
      final http = SubscriptionHttp(
        userAgent: () => 'MeowX-test',
        proxyFor: (_) => 'PROXY 127.0.0.1:${killer.port}',
        context: clientCtx,
      );
      final options = Options(responseType: ResponseType.plain);
      return SubscriptionFetcher(
        attempt: (route, ip, timeout, cancel) => http.get(url, options, route, ip, timeout, cancel),
        systemLookup: (_) async => const [],
        dohLookup: (_, _, _) async => doh,
        log: logs.add,
      );
    }

    test('经本机代理时握手被掐，直连成功', () async {
      final url = 'https://127.0.0.1:${server.port}/x/TOKEN1';
      final res = await real(url).fetch(Uri.parse(url), coreRunning: true);
      expect(res.statusCode, 200);
      expect(res.data, 'proxies: [] # /x/TOKEN1');
      expect(logs.first, contains('经本机代理（127.0.0.1）失败'));
      expect(logs.first, isNot(contains('TOKEN1')));
      expect(logs.last, contains('订阅换路成功：直连'));
    });

    test('本机解析不到（相当于被污染）：按加密 DNS 解出的 IP 连上，SNI 与证书按原域名', () async {
      final url = 'https://sub.test:${server.port}/x/TOKEN2';
      final res = await real(url, doh: [InternetAddress.loopbackIPv4]).fetch(Uri.parse(url), coreRunning: false);
      expect(res.data, 'proxies: [] # /x/TOKEN2');
      expect(logs.last, contains('换 DNS 解析（sub.test → 127.0.0.1）'));
    });

    test('按 IP 连时证书照常校验：证书里没有这个域名就失败，最后给人看的话', () async {
      final url = 'https://evil.test:${server.port}/x/TOKEN3';
      await expectLater(
        real(url, doh: [InternetAddress.loopbackIPv4]).fetch(Uri.parse(url), coreRunning: false),
        throwsA(isA<SubscriptionFetchException>().having((e) => e.toString(), 'message', contains('已尝试直连 / 换 DNS 解析'))),
      );
      expect(logs.join('\n'), contains('换 DNS 解析（evil.test → 127.0.0.1）失败：handshake'));
      expect(logs.join('\n'), isNot(contains('TOKEN3')));
    });
  });
}
