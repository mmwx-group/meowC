import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 拉订阅（导入 / 刷新 / 账户订阅 / 主控推送重拉 / 到期同步都经 [Request.getFileResponseForUrl] 走到这里）时，
/// 连接层失败（握手被掐、连接被重置 / 关闭 / 拒绝、连不上、超时）就换一条路再试，成功即止，每条路各一次。
///
/// 起因（2026-11-20）：Windows 用户在内置「直连」档下导入订阅报 `DioException [unknown]: null / HandshakeException:
/// Connection terminated during handshake`，同一台机器上另一个客户端也握不上，FlClash 却能拉到；服务器本身不挑客户端。
/// 以前只有「经本机内核失败 → 直连再试一次」，而且只认 SocketException / HttpException，握手被掐（HandshakeException）
/// 连这一次都不重试。
///
/// 路：
/// 1. 内核起着时经本机混合端口（走规则 / 当前节点）；内核没起时直连（[SubFetchRoute.direct]，这时本来就是第一条）。
/// 2. 第一条经内核时，直连再试。
/// 3. 用加密 DNS（阿里 223.5.5.5 + Cloudflare 1.1.1.1，按 IP 访问、证书照常校验）解析，按解析出的 IP 直连，
///    TLS 的 SNI 与证书校验仍按原域名（防 DNS 污染 / 被解析到连不上的地址）；解析结果全在本机解析结果里就跳过这一步，
///    至多试 [SubFetchPolicy.maxResolvedIps] 个地址。
/// 「绕开系统 / 环境变量代理直连」不单列：Dart 的 HttpClient 只按我们给的 findProxy 走，从不读系统代理与
/// HTTP(S)_PROXY，第 1 / 2 条的「直连」本来就不经它们（别的软件的 TUN 在网卡层接管，应用层绕不开）。
///
/// 时限：从第一条失败起，后面的路连同 DNS 查询共用 [SubFetchPolicy.budget]（25 秒，含第一条）里剩下的时间，
/// 每条路的连接超时取「这条路的上限」与剩余时间的较小者，剩不到 2 秒就不再试。只管连接阶段，连上之后下载大订阅不受它限。
/// 取消（[CancelToken]）立刻停：不再换路，抛 Dio 的 cancel。
enum SubFetchRoute { viaCore, direct, resolvedIp }

extension SubFetchRouteLabel on SubFetchRoute {
  String get label => switch (this) {
    SubFetchRoute.viaCore => '经本机代理',
    SubFetchRoute.direct => '直连',
    SubFetchRoute.resolvedIp => '换 DNS 解析',
  };
}

/// 失败的类型（给人看的那句话与日志用）
enum SubFetchFailureKind { handshake, reset, closed, refused, timeout, dns, other }

/// 一条路的失败记录
class SubFetchFailure {
  SubFetchFailure({required this.route, required this.host, this.ip, required this.error});

  final SubFetchRoute route;
  final String host;
  final InternetAddress? ip;
  final Object error;

  SubFetchFailureKind get kind => SubFetchPolicy.kindOf(error);

  /// 日志用的一行（不带订阅地址的路径与查询串：里面常有 token）
  String describe() {
    final where = ip == null ? host : '$host → ${ip!.address}';
    return '${route.label}（$where）失败：${kind.name} ${SubFetchPolicy.scrub(SubFetchPolicy.errorText(error), host)}';
  }
}

/// 全部路都失败时抛的错：[toString] 是给人看的一句话（界面直接显示它）
class SubscriptionFetchException implements Exception {
  SubscriptionFetchException(this.host, this.failures);

  final String host;
  final List<SubFetchFailure> failures;

  String get message => SubFetchPolicy.summary(host, failures);

  @override
  String toString() => message;
}

/// 纯逻辑：重不重试、按什么顺序、跳不跳过、时限、给人看的话
abstract final class SubFetchPolicy {
  /// 全部路（含第一条）的连接阶段合计上限
  static const budget = Duration(seconds: 25);

  /// 剩下的时间不到这么多就不再试下一条
  static const minAttempt = Duration(seconds: 2);

  /// 加密 DNS 查询的上限
  static const dohTimeout = Duration(seconds: 4);

  /// 换 DNS 解析后至多试几个地址
  static const maxResolvedIps = 2;

  /// 每条路连接阶段（连上 + TLS 握手）的上限
  static Duration cap(SubFetchRoute route) => switch (route) {
    SubFetchRoute.viaCore => const Duration(seconds: 12),
    SubFetchRoute.direct => const Duration(seconds: 10),
    SubFetchRoute.resolvedIp => const Duration(seconds: 6),
  };

  /// 依次要试的路（第一条就是以前的走法）
  static List<SubFetchRoute> routes({required bool coreRunning}) => coreRunning
      ? const [SubFetchRoute.viaCore, SubFetchRoute.direct, SubFetchRoute.resolvedIp]
      : const [SubFetchRoute.direct, SubFetchRoute.resolvedIp];

  /// 连接层的失败才换路：拿到了 HTTP 状态码（4xx / 5xx）、证书不对、用户取消都不重试
  static bool shouldRetry(Object error) {
    if (error is DioException) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.connectionError => true,
        DioExceptionType.unknown => _connectionLayer(error.error),
        _ => false,
      };
    }
    return _connectionLayer(error);
  }

  static bool _connectionLayer(Object? e) =>
      e is SocketException || e is TlsException || e is HttpException || e is TimeoutException;

  /// 加密 DNS 解出来、本机解析结果里没有的地址（保持加密 DNS 给的顺序、去重，至多 [max] 个）；
  /// 全在本机结果里 = 空（这一步跳过）
  static List<InternetAddress> freshAddresses(
    Iterable<InternetAddress> system,
    Iterable<InternetAddress> resolved, {
    int max = maxResolvedIps,
  }) {
    final known = {for (final a in system) a.address};
    final out = <InternetAddress>[];
    for (final a in resolved) {
      if (known.add(a.address)) out.add(a);
      if (out.length >= max) break;
    }
    return out;
  }

  /// 这一条路的连接超时：第一条用它自己的上限；之后取上限与剩余时间的较小者，剩不到 [minAttempt] 返回 null（不试了）
  static Duration? connectTimeout(SubFetchRoute route, {required bool first, required Duration remaining}) {
    final c = cap(route);
    if (first) return c;
    if (remaining < minAttempt) return null;
    return remaining < c ? remaining : c;
  }

  static SubFetchFailureKind kindOf(Object error) {
    Object e = error;
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return SubFetchFailureKind.timeout;
        default:
          e = error.error ?? error;
      }
    }
    if (e is TlsException) return SubFetchFailureKind.handshake;
    if (e is TimeoutException) return SubFetchFailureKind.timeout;
    final text = errorText(e).toLowerCase();
    if (e is SocketException) {
      final code = e.osError?.errorCode;
      if (text.contains('failed host lookup') || text.contains('no address associated')) return SubFetchFailureKind.dns;
      if (code == 54 || code == 104 || code == 10054 || text.contains('reset')) return SubFetchFailureKind.reset;
      if (code == 61 || code == 111 || code == 10061 || text.contains('refused')) return SubFetchFailureKind.refused;
      if (code == 60 || code == 110 || code == 10060 || text.contains('timed out')) return SubFetchFailureKind.timeout;
      if (text.contains('closed')) return SubFetchFailureKind.closed;
      return SubFetchFailureKind.other;
    }
    if (text.contains('handshake')) return SubFetchFailureKind.handshake;
    if (text.contains('reset')) return SubFetchFailureKind.reset;
    if (text.contains('closed') || text.contains('terminated')) return SubFetchFailureKind.closed;
    return SubFetchFailureKind.other;
  }

  /// 错误的原文（DioException 换成它包着的那个，免得只有「[unknown]: null」）
  static String errorText(Object error) {
    if (error is DioException) {
      final inner = error.error;
      if (inner != null) return '${inner.runtimeType}: ${inner is SocketException || inner is TlsException ? _ioMessage(inner) : inner}';
      return 'DioException ${error.type.name}${error.message == null ? '' : ': ${error.message}'}';
    }
    if (error is SocketException || error is TlsException) return '${error.runtimeType}: ${_ioMessage(error)}';
    return '$error';
  }

  static String _ioMessage(Object e) => switch (e) {
    SocketException(:final message, :final osError) =>
      [if (message.isNotEmpty) message, if (osError != null) osError.message].join(' / '),
    TlsException(:final message, :final osError) =>
      [if (message.isNotEmpty) message, if (osError != null) osError.message].join(' / '),
    _ => '$e',
  };

  /// 去掉文字里的完整地址（路径与查询串里常有 token），换成主机名
  static String scrub(String text, String host) =>
      text.replaceAll(RegExp(r',?\s*uri = \S+'), '').replaceAll(RegExp(r'https?://[^\s,]+'), host);

  /// 给人看的那句话
  static String summary(String host, List<SubFetchFailure> failures) {
    final kinds = failures.map((f) => f.kind).toSet();
    final what = kinds.contains(SubFetchFailureKind.handshake) || kinds.contains(SubFetchFailureKind.closed)
        ? '握手被中断'
        : kinds.contains(SubFetchFailureKind.reset)
        ? '连接被重置'
        : kinds.contains(SubFetchFailureKind.timeout)
        ? '连接超时'
        : kinds.contains(SubFetchFailureKind.refused)
        ? '连接被拒绝'
        : kinds.length == 1 && kinds.contains(SubFetchFailureKind.dns)
        ? '解析不到这个域名'
        : '连不上';
    final tried = <String>[];
    for (final f in failures) {
      if (!tried.contains(f.route.label)) tried.add(f.route.label);
    }
    final triedText = tried.isEmpty
        ? ''
        : tried.length == 1
        ? '，已尝试${tried.first}，没连上'
        : '，已尝试${tried.join(' / ')}，都没连上';
    return '连接订阅地址（$host）时$what$triedText。可能是其它代理软件或网络在拦截这个地址，可以先退出其它代理软件再试。';
  }
}

/// 一次尝试：走哪条路（[ip] 只在 [SubFetchRoute.resolvedIp] 时有）
typedef SubFetchAttemptFn =
    Future<Response<dynamic>> Function(SubFetchRoute route, InternetAddress? ip, Duration connectTimeout, CancelToken cancel);
typedef SubFetchLookupFn = Future<List<InternetAddress>> Function(String host);
typedef SubFetchDohFn = Future<List<InternetAddress>> Function(String host, Duration timeout, CancelToken cancel);

/// 按 [SubFetchPolicy] 换路重试。网络、时钟、日志都可注入（测试用）。
class SubscriptionFetcher {
  SubscriptionFetcher({
    required this.attempt,
    required this.systemLookup,
    required this.dohLookup,
    DateTime Function()? now,
    void Function(String line)? log,
    this.budget = SubFetchPolicy.budget,
  }) : _now = now ?? DateTime.now,
       _log = log ?? ((_) {});

  final SubFetchAttemptFn attempt;
  final SubFetchLookupFn systemLookup;
  final SubFetchDohFn dohLookup;
  final DateTime Function() _now;
  final void Function(String line) _log;
  final Duration budget;

  Future<Response<dynamic>> fetch(Uri uri, {required bool coreRunning, CancelToken? cancel}) async {
    final token = cancel ?? CancelToken();
    final host = uri.host;
    final start = _now();
    Duration remaining() => budget - _now().difference(start);
    final failures = <SubFetchFailure>[];
    var first = true;

    // 试一次；成功返回响应，可以换路的失败返回 null（记下来），别的失败直接抛
    Future<Response<dynamic>?> tryRoute(SubFetchRoute route, {InternetAddress? ip}) async {
      final timeout = SubFetchPolicy.connectTimeout(route, first: first, remaining: remaining());
      if (timeout == null) return null;
      first = false;
      try {
        final res = await attempt(route, ip, timeout, token);
        if (failures.isNotEmpty) {
          _log('订阅换路成功：${route.label}（${ip == null ? host : '$host → ${ip.address}'}），之前 ${failures.length} 条路失败');
        }
        return res;
      } catch (e) {
        _throwIfCancelled(token, uri);
        if (!SubFetchPolicy.shouldRetry(e)) rethrow;
        final f = SubFetchFailure(route: route, host: host, ip: ip, error: e);
        failures.add(f);
        _log('订阅拉取 ${f.describe()}');
        return null;
      }
    }

    for (final route in SubFetchPolicy.routes(coreRunning: coreRunning)) {
      _throwIfCancelled(token, uri);
      if (route != SubFetchRoute.resolvedIp) {
        final res = await tryRoute(route);
        if (res != null) return res;
        continue;
      }
      // 换 DNS 解析：主机名本身是 IP 时没什么可解析的
      if (InternetAddress.tryParse(host) != null) continue;
      final left = remaining();
      if (left < SubFetchPolicy.minAttempt) break;
      final dnsTimeout = left < SubFetchPolicy.dohTimeout ? left : SubFetchPolicy.dohTimeout;
      final results = await Future.wait([
        systemLookup(host).timeout(dnsTimeout, onTimeout: () => const <InternetAddress>[]).catchError((_) => const <InternetAddress>[]),
        dohLookup(host, dnsTimeout, token).catchError((_) => const <InternetAddress>[]),
      ]);
      _throwIfCancelled(token, uri);
      final fresh = SubFetchPolicy.freshAddresses(results[0], results[1]);
      if (fresh.isEmpty) {
        _log(
          results[1].isEmpty
              ? '订阅拉取：加密 DNS 没解析出 $host，跳过换 DNS 解析'
              : '订阅拉取：加密 DNS 解析 $host 的结果与本机一致（${results[1].map((a) => a.address).join(', ')}），跳过换 DNS 解析',
        );
        continue;
      }
      for (final ip in fresh) {
        _throwIfCancelled(token, uri);
        final res = await tryRoute(SubFetchRoute.resolvedIp, ip: ip);
        if (res != null) return res;
      }
    }
    _throwIfCancelled(token, uri);
    if (failures.isEmpty) {
      // 不可能：第一条路一定试过（失败才会走到这里）
      throw SubscriptionFetchException(host, failures);
    }
    final error = SubscriptionFetchException(host, failures);
    _log('订阅拉取全部失败：${error.message}');
    throw error;
  }

  static void _throwIfCancelled(CancelToken token, Uri uri) {
    if (token.isCancelled) {
      throw DioException.requestCancelled(requestOptions: RequestOptions(path: uri.toString()), reason: token.cancelError?.error);
    }
  }
}

/// 真的去连：三种路各自一个 HttpClient。[context] 只给测试用（信任测试证书）；生产里 null。
class SubscriptionHttp {
  SubscriptionHttp({
    required this.userAgent,
    required this.proxyFor,
    this.context,
    this.acceptBadCertificates = false,
  });

  /// 每次发请求时的 UA（缺省的那个；请求头里给了就盖掉它）
  final String Function() userAgent;

  /// 经本机代理那条路的 findProxy（内核没起时返回 DIRECT）
  final String Function(Uri uri) proxyFor;
  final SecurityContext? context;

  /// 经本机代理 / 直连两条路照旧接受任何证书（以前的行为：全局 HttpOverrides 一律放行，见 lib/common/http.dart）；
  /// 换 DNS 解析那条路不受它影响，一律按原域名校验证书。
  final bool acceptBadCertificates;

  static const sendTimeout = Duration(seconds: 15);
  static const receiveTimeout = Duration(seconds: 30);

  Future<Response<dynamic>> get(
    String url,
    Options options,
    SubFetchRoute route,
    InternetAddress? ip,
    Duration connectTimeout,
    CancelToken cancel,
  ) {
    final target = Uri.parse(url);
    final dio = Dio(BaseOptions(connectTimeout: connectTimeout, sendTimeout: sendTimeout, receiveTimeout: receiveTimeout));
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient(context: context)
          ..autoUncompress = false
          ..userAgent = userAgent();
        if (acceptBadCertificates) client.badCertificateCallback = (_, _, _) => true;
        switch (route) {
          case SubFetchRoute.viaCore:
            client.findProxy = proxyFor;
          case SubFetchRoute.direct:
            client.findProxy = (_) => 'DIRECT';
          case SubFetchRoute.resolvedIp:
            client.findProxy = (_) => 'DIRECT';
            client.connectionFactory = (uri, _, _) => Future.value(_connect(uri, target.host, ip!));
        }
        return client;
      },
    );
    return dio.get<dynamic>(url, options: options, cancelToken: cancel).whenComplete(() => dio.close());
  }

  /// 连 [ip]、TLS 照原域名握手（SNI 与证书校验都是 [host]）；跳转到别的主机时照常按主机名连
  ConnectionTask<Socket> _connect(Uri uri, String host, InternetAddress ip) {
    final secure = uri.scheme == 'https';
    final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
    if (uri.host != host) {
      return secure
          ? _secureTask(Socket.startConnect(uri.host, port), uri.host)
          : _plainTask(Socket.startConnect(uri.host, port));
    }
    final task = Socket.startConnect(ip, port);
    return secure ? _secureTask(task, host) : _plainTask(task);
  }

  ConnectionTask<Socket> _plainTask(Future<ConnectionTask<Socket>> task) =>
      ConnectionTask.fromSocket(task.then((t) => t.socket), () => task.then((t) => t.cancel()));

  ConnectionTask<Socket> _secureTask(Future<ConnectionTask<Socket>> task, String host) => ConnectionTask.fromSocket(
    task.then((t) => t.socket).then((s) => SecureSocket.secure(s, host: host, context: context)),
    () => task.then((t) => t.cancel()),
  );

  /// 加密 DNS：国内（阿里 223.5.5.5）与国外（Cloudflare 1.1.1.1）同时查 A 记录，合并两边的结果（国内的在前）。
  /// 按 IP 访问、证书照常校验、不经任何代理。
  static Future<List<InternetAddress>> doh(String host, Duration timeout, CancelToken cancel) async {
    final lists = await Future.wait([
      _dohJson(Uri.https('223.5.5.5', '/resolve', {'name': host, 'type': '1'}), const {}, timeout, cancel),
      _dohJson(Uri.https('1.1.1.1', '/dns-query', {'name': host, 'type': 'A'}), const {'accept': 'application/dns-json'}, timeout, cancel),
    ]);
    final seen = <String>{};
    return [
      for (final list in lists)
        for (final a in list)
          if (seen.add(a.address)) a,
    ];
  }

  static Future<List<InternetAddress>> _dohJson(Uri uri, Map<String, String> headers, Duration timeout, CancelToken cancel) async {
    final dio = Dio(BaseOptions(connectTimeout: timeout, receiveTimeout: timeout, sendTimeout: timeout, headers: headers));
    dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT');
    try {
      final res = await dio.getUri<String>(uri, options: Options(responseType: ResponseType.plain), cancelToken: cancel).timeout(timeout);
      return parseDohJson(res.data ?? '');
    } catch (_) {
      return const [];
    } finally {
      dio.close();
    }
  }

  /// 解析 DNS JSON（Google / Cloudflare / 阿里同一格式）里的 A 记录
  static List<InternetAddress> parseDohJson(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map || json['Status'] != 0) return const [];
      final answers = json['Answer'];
      if (answers is! List) return const [];
      return [
        for (final a in answers)
          if (a is Map && a['type'] == 1 && a['data'] is String) ?InternetAddress.tryParse(a['data'] as String),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 本机解析（只取 IPv4，与加密 DNS 的 A 记录比）
  static Future<List<InternetAddress>> systemLookup(String host) async =>
      (await InternetAddress.lookup(host)).where((a) => a.type == InternetAddressType.IPv4).toList();
}
