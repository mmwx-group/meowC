import 'dart:convert';

import 'package:bett_box/meowx/panel/ggy.dart';
import 'package:flutter_test/flutter_test.dart';

// 只用假 token。
const _token = 'ctecsfw_TESTtoken0000000000AAAA';
const _url = 'https://www.guguyun.com/cany_tencentecs/firewall/whitelist?token=$_token';

void main() {
  test('token 解析：裸 token / 整条链接 / 带空白；非法字符、太短、太长、链接里没有 token 都不收', () {
    expect(parseGgyToken(_token), (_token, null));
    expect(parseGgyToken('  $_token \n'), (_token, null));
    expect(parseGgyToken(_url), (_token, null));
    expect(parseGgyToken(' $_url '), (_token, null));
    // 不带协议头、token 不在第一个参数、后面还有参数 / 片段
    expect(parseGgyToken('www.guguyun.com/cany_tencentecs/firewall/whitelist?a=1&token=$_token&b=2#x'), (_token, null));
    expect(parseGgyToken('token=$_token'), (_token, null));
    // 不强制前缀；8 位与 200 位是边界
    expect(normalizeGgyToken('Ab3_-xyz'), 'Ab3_-xyz');
    expect(normalizeGgyToken('a' * 200), 'a' * 200);

    expect(parseGgyToken(''), (null, ggyTokenEmptyMessage));
    expect(parseGgyToken('   '), (null, ggyTokenEmptyMessage));
    for (final bad in [
      'abc1234',                                  // 7 位
      'a' * 201,
      'ctecsfw_TEST token0000',                   // 中间空白
      'ctecsfw_TEST.token0000',                   // 非法字符
      'ctecsfw_TEST%2Btoken00',
      '咕咕云token0000000',
      'https://www.guguyun.com/whitelist',         // 链接里没有 token
      'https://www.guguyun.com/whitelist?token=',  // token 为空
      'https://www.guguyun.com/whitelist?mytoken=$_token',
      'https://www.guguyun.com/whitelist?token=abc',
    ]) {
      expect(parseGgyToken(bad), (null, ggyTokenInvalidMessage), reason: bad);
    }
  });

  test('添加：按规范化后的字符串去重、上限 20 个', () {
    expect(checkNewGgyToken(const [], _url), (_token, null));
    expect(checkNewGgyToken(const [_token], ' $_url '), (null, ggyTokenDuplicateMessage));
    expect(checkNewGgyToken(const [_token], _token), (null, ggyTokenDuplicateMessage));
    // 大小写不同算不同的 token
    expect(checkNewGgyToken(const [_token], _token.toLowerCase()), (_token.toLowerCase(), null));
    expect(checkNewGgyToken(const [_token], 'bad'), (null, ggyTokenInvalidMessage));
    final full = [for (var i = 0; i < ggyMaxTokens; i++) 'ctecsfw_TESTtoken${i.toString().padLeft(4, '0')}'];
    expect(checkNewGgyToken(full, _token), (null, ggyTokensFullMessage));
    expect(checkNewGgyToken(full.sublist(1), _token), (_token, null));

    // 上报列表兜底：不合法的跳过、去重、保持顺序、最多 20 个
    expect(ggyReportTokens([' $_token', 'bad', _token, 'Ab3_-xyz']), [_token, 'Ab3_-xyz']);
    expect(ggyReportTokens([...full, _token]).length, ggyMaxTokens);
  });

  test('脱敏：含 _ 留第一个 _ 及之前 + 后 4 位，否则只留后 4 位', () {
    expect(maskGgyToken(_token), 'ctecsfw_••••AAAA');
    expect(maskGgyToken('ctecsfw_abc_defgAAAA'), 'ctecsfw_••••AAAA');
    expect(maskGgyToken('abcdefgh1234'), '••••1234');
    expect(maskGgyToken('-abcdefgh_1234'), '-abcdefgh_••••1234');
  });

  test('上报地址', () {
    expect(ggyReportUrl(_token), _url);
  });

  test('脱敏日志文字：token= 后面那段与原样出现的 token 都换掉', () {
    expect(redactGgy('Get "$_url": dial tcp: i/o timeout'),
        'Get "https://www.guguyun.com/cany_tencentecs/firewall/whitelist?token=ctecsfw_••••AAAA": dial tcp: i/o timeout');
    expect(redactGgy('echo $_token back', const [_token]), 'echo ctecsfw_••••AAAA back');
    expect(redactGgy('nothing here'), 'nothing here');
  });

  group('应答判断', () {
    final at = DateTime(2026, 10, 29, 9, 5);
    GgyResult judge(int status, Object? body, {String error = ''}) =>
        GgyResult.judge(status: status, body: body is String ? body : json.encode(body), error: error, at: at);

    test('status 200（数字 / 字符串）→ 成功，msg 写进日志', () {
      final r = judge(200, {'status': 200, 'msg': '已加入白名单', 'data': []});
      expect(r.kind, GgyResultKind.ok);
      expect(r.summary, '成功 · 09:05');
      expect(r.logLine(_token), 'GGY 加白 ctecsfw_••••AAAA：成功（已加入白名单）');
      expect(judge(200, {'status': '200'}).kind, GgyResultKind.ok);
      expect(judge(200, {'status': ' 200 '}).kind, GgyResultKind.ok);
      expect(judge(200, '{"status":200.0}').kind, GgyResultKind.ok);
      expect(judge(200, {'status': 200}).logLine(_token), 'GGY 加白 ctecsfw_••••AAAA：成功');
    });

    test('status 400 + 「无效或已失效」→ token 无效（线上实测的应答）', () {
      final r = judge(200, '{"status":400,"msg":"白名单分享链接无效或已失效","data":[]}');
      expect(r.kind, GgyResultKind.tokenInvalid);
      expect(r.reason, '白名单分享链接无效或已失效');
      expect(r.summary, 'token 无效或已失效');
      expect(r.logLine(_token), 'GGY 加白 ctecsfw_••••AAAA：失败（白名单分享链接无效或已失效）');
      expect(judge(200, {'status': '400', 'msg': '链接已失效'}).kind, GgyResultKind.tokenInvalid);
    });

    test('status 别的值 → 失败，原因用 msg，msg 为空用 status <值>', () {
      final busy = judge(200, {'status': 500, 'msg': '系统繁忙'});
      expect(busy.kind, GgyResultKind.failed);
      expect(busy.summary, '失败：系统繁忙');
      expect(busy.logLine(_token), 'GGY 加白 ctecsfw_••••AAAA：失败（系统繁忙）');
      expect(judge(200, {'status': 403}).reason, 'status 403');
      expect(judge(200, {'status': 'error', 'msg': ''}).reason, 'status error');
      // 400 但不是「无效 / 失效」：普通失败
      expect(judge(200, {'status': 400, 'msg': '参数错误'}).kind, GgyResultKind.failed);
    });

    test('没有 status 字段 → 当作成功，日志带上应答开头 160 字节', () {
      final long = '{"ok":true,"msg":"已加白","pad":"${'咕' * 200}"}';
      final r = judge(200, long);
      expect(r.kind, GgyResultKind.ok);
      expect(utf8.encode(r.note).length, lessThanOrEqualTo(160));
      expect(r.note, startsWith('{"ok":true'));
      expect(long, startsWith(r.note));
      expect(r.logLine(_token), startsWith('GGY 加白 ctecsfw_••••AAAA：成功（已加白；应答没有 status：{"ok":true'));
      expect(judge(200, '{}').note, '{}');
    });

    test('不是 JSON 对象 → 失败（应答无法解析）', () {
      final r = judge(200, '<html>blocked</html>');
      expect(r.kind, GgyResultKind.failed);
      expect(r.reason, '应答无法解析');
      expect(r.logLine(_token), 'GGY 加白 ctecsfw_••••AAAA：失败（应答无法解析：<html>blocked</html>）');
      expect(judge(200, '').reason, '应答无法解析');
      expect(judge(200, '[1,2]').reason, '应答无法解析');
    });

    test('HTTP 非 200 / 连不上 → 失败', () {
      final r = judge(404, '<html>404</html>');
      expect(r.kind, GgyResultKind.failed);
      expect(r.summary, '失败：HTTP 404');
      expect(r.logLine(_token), 'GGY 加白 ctecsfw_••••AAAA：失败（HTTP 404）');
      // 连不上时 HTTP 状态码为 0，原因是核心的错误
      expect(judge(0, '', error: 'dial tcp: i/o timeout').logLine(_token), 'GGY 加白 ctecsfw_••••AAAA：失败（dial tcp: i/o timeout）');
    });
  });

  test('核心结果按 url 认回 token；url.Error 只留原因、token 脱敏', () {
    const other = 'abcdefgh1234';
    final raw = json.encode([
      {'url': _url, 'status': 200, 'body': '{"status":400,"msg":"白名单分享链接无效或已失效","data":[]}'},
      {
        'url': ggyReportUrl(other),
        'status': 0,
        'error': 'Get "${ggyReportUrl(other)}": tls: failed to verify certificate: x509: certificate signed by unknown authority',
      },
      {'url': 'https://elsewhere.example.com/', 'status': 200, 'body': '{}'},
    ]);
    final out = parseGgyReport(raw, const [_token, other]);
    expect(out.keys, [_token, other]);
    expect(out[_token]!.kind, GgyResultKind.tokenInvalid);
    expect(out[other]!.reason, 'tls: failed to verify certificate: x509: certificate signed by unknown authority');
    expect(parseGgyReport('', const [_token]), isEmpty);
    expect(parseGgyReport('not json', const [_token]), isEmpty);
  });
}
