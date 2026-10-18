import 'package:bett_box/meowx/state/traffic_kind.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

TrackerInfo _conn(String host, List<String> chains, {String ip = '198.51.100.1', String port = '443', String network = 'tcp'}) =>
    TrackerInfo(
      id: '1',
      upload: 0,
      download: 0,
      start: DateTime(2026),
      metadata: Metadata(network: network, host: host, destinationIP: ip, destinationPort: port),
      chains: chains,
      rule: 'Match',
      rulePayload: '',
    );

void main() {
  test('连接分类：推送看 Google 推送（GMS / FCM）的域名与 TCP 5228–5230，DNS 看 53 / 853 / DoH，去向看最终出站', () {
    expect(connectionKinds(_conn('mtalk.google.com', ['香港 01', '节点选择'], port: '5228')), {ActivityKind.push, ActivityKind.proxy});
    expect(connectionKinds(_conn('alt3-mtalk.google.com', ['香港 01'])), {ActivityKind.push, ActivityKind.proxy});
    expect(connectionKinds(_conn('fcm.googleapis.com', ['香港 01'])), {ActivityKind.push, ActivityKind.proxy});
    expect(connectionKinds(_conn('android.googleapis.com', ['DIRECT'])), {ActivityKind.push, ActivityKind.direct});
    expect(connectionKinds(_conn('', ['香港 01'], port: '5229')), {ActivityKind.push, ActivityKind.proxy});
    expect(connectionKinds(_conn('', ['香港 01'], port: '5228', network: 'udp')), {ActivityKind.proxy});
    expect(connectionKinds(_conn('notmtalk.google.com.evil', ['香港 01'])), {ActivityKind.proxy});
    expect(connectionKinds(_conn('1-courier.push.apple.com', ['香港 01'])), {ActivityKind.proxy});   // 安卓不认 APNs
    expect(connectionKinds(_conn('dns.google', ['香港 01'])), {ActivityKind.dns, ActivityKind.proxy});
    expect(connectionKinds(_conn('', ['DIRECT'], port: '53', network: 'udp')), {ActivityKind.dns, ActivityKind.direct});
    expect(connectionKinds(_conn('www.google.com', ['香港 01'])), {ActivityKind.proxy});
    expect(connectionKinds(_conn('ads.example', ['REJECT', '广告'])), <ActivityKind>{});   // 拒绝的不算直连也不算代理
  });

  test('日志分类：按 mihomo 连接日志的目标与 using 认，DNS 模块的日志算 DNS', () {
    expect(logKinds('[TCP] 10.0.0.2:51234 --> www.youtube.com:443 match GeoSite(youtube) using 节点选择[香港 01]'), {ActivityKind.proxy});
    expect(logKinds('[TCP] 10.0.0.2:51234 --> api.example.cn:443 match GeoSite(cn) using DIRECT'), {ActivityKind.direct});
    expect(logKinds('[TCP] 10.0.0.2:51234 --> mtalk.google.com:5228 match Match using DIRECT'), {ActivityKind.push, ActivityKind.direct});
    expect(logKinds('[UDP] 10.0.0.2:5353 --> 8.8.8.8:53 match Match using 节点选择[香港 01]'), {ActivityKind.dns, ActivityKind.proxy});
    expect(logKinds('[DNS] resolve example.com failed'), {ActivityKind.dns});
    expect(logKinds('[TCP] 10.0.0.2:1 --> ads.example:443 match RuleSet(ads) using REJECT'), <ActivityKind>{});
    expect(logKinds('节点 伦敦 01 测速超时'), <ActivityKind>{});
  });

  test('规则写法同 iOS / 配置文件', () {
    expect(ruleDisplay('GeoSite', 'apple'), 'GEOSITE,apple');
    expect(ruleDisplay('DomainSuffix', 'example.com'), 'DOMAIN-SUFFIX,example.com');
    expect(ruleDisplay('RuleSet', 'telegram'), 'RULE-SET,telegram');
    expect(ruleDisplay('Match', ''), 'MATCH');
    expect(ruleDisplay('SomethingNew', 'x'), 'SOMETHINGNEW,x');
  });
}
