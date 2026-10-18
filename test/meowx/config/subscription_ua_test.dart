import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/meowx/config/subscription_headers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

// 走真实的拉订阅请求（Request.getFileResponseForUrl）打本机的模拟订阅服务：UA 里有 clash 才给 Clash 配置，
// 否则回 base64 的通用订阅。确认 App 的 UA 先发、换 UA 时请求头真的换掉了。

void main() {
  late HttpServer server;
  final uas = <String?>[];

  setUpAll(() async {
    globalState.packageInfo = PackageInfo(appName: 'MeowX', packageName: 'com.miaomiaowux.app', version: '0.3.6', buildNumber: '28');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      final ua = req.headers.value(HttpHeaders.userAgentHeader);
      uas.add(ua);
      final clash = (ua ?? '').toLowerCase().contains('clash');
      req.response
        ..headers.contentType = ContentType.html
        ..write(clash ? 'proxies:\n  - {name: a, type: ss, server: a.example, port: 1, cipher: aes-128-gcm, password: p}\n' : base64.encode(utf8.encode('vmess://eyJhZGQiOiJhIn0=\n')))
        ..close();
    });
  });

  tearDownAll(() => server.close(force: true));

  test('订阅只认 clash：App 的 UA 拿到通用订阅，换 clash.meta 后拿到 Clash 配置', () async {
    final url = 'http://127.0.0.1:${server.port}/sub?token=t';
    final response = await fetchClashSubscription(
      (ua) => request.getFileResponseForUrl(url, userAgent: ua),
      (r) => r.data as List<int>,
    );
    expect(utf8.decode(response.data as List<int>), startsWith('proxies:'));
    expect(uas, [globalState.ua, clashCompatUa]);
    expect(globalState.ua, startsWith('mihomo/1.19.0 MeowX/0.3.6'));
  });
}
