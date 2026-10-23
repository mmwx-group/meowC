import 'package:bett_box/meowx/panel/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('主控证书失败原因（#1382）', () {
    test('认得的原因换成中文', () {
      expect(certErrorReason({'error': 'license is not configured'}), '主控尚未激活许可证，无法登录客户端');
      expect(
        certErrorReason({'error': 'certificate domain is claimed by another license'}),
        '主控地址的域名已绑定在另一份许可证名下',
      );
      expect(
        certErrorReason({'error': '  主控未配置对外域名(系统设置的订阅地址/主控地址),无法签发客户端加密证书  '}),
        '主控还没填对外域名，请管理员在面板「系统设置 → 主控地址」填好后重试',
      );
    });

    test('按主控给的 code 认', () {
      expect(certErrorReason({'error': 'whatever', 'code': 'no_license'}), '主控尚未激活许可证，无法登录客户端');
      expect(certErrorReason({'error': 'x', 'code': 'domain_claimed'}), '主控地址的域名已绑定在另一份许可证名下');
      expect(certErrorReason({'error': 'x', 'code': 'no_domain'}), startsWith('主控还没填对外域名'));
      expect(
        certErrorReason({'error': 'certificate request rejected (403): license expired', 'code': 'issuer_error'}),
        '主控向许可证服务申请证书失败：certificate request rejected (403): license expired'
        '（管理员可在面板「系统设置 → 主控地址 → 客户端证书状态」查看）',
      );
    });

    test('退避中：带上次失败的原因与等待时间', () {
      expect(
        certErrorReason({
          'error': 'license is not configured(29s 后重试)',
          'code': 'backoff',
          'cause': 'no_license',
          'retry_after': 29,
        }),
        '上次签发证书失败，约 29 秒后自动重试；主控尚未激活许可证，无法登录客户端',
      );
      expect(
        certErrorReason({
          'error': 'dial tcp: i/o timeout(10s 后重试)',
          'code': 'backoff',
          'cause': 'issuer_error',
          'retry_after': '10',
        }),
        startsWith('上次签发证书失败，约 10 秒后自动重试；主控向许可证服务申请证书失败：dial tcp: i/o timeout'),
      );
      // 别的请求正在签发：不是失败
      expect(certErrorReason({'error': '证书签发中,请稍后重试', 'code': 'backoff', 'retry_after': 5}), '主控正在签发证书，请稍后重试');
    });

    test('其他原因原样带上', () {
      expect(certErrorReason({'error': '  证书验签失败  '}), '证书验签失败');
    });

    test('不是 JSON 或没有 error 时为空', () {
      expect(certErrorReason('<html>404</html>'), '');
      expect(certErrorReason(null), '');
      expect(certErrorReason({'error': ''}), '');
      expect(certErrorReason({'domain': 'x'}), '');
    });
  });
}
