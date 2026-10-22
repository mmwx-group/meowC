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
    });

    test('其他原因原样带上', () {
      expect(certErrorReason({'error': '  未配置对外域名(主控地址)  '}), '未配置对外域名(主控地址)');
    });

    test('不是 JSON 或没有 error 时为空', () {
      expect(certErrorReason('<html>404</html>'), '');
      expect(certErrorReason(null), '');
      expect(certErrorReason({'error': ''}), '');
      expect(certErrorReason({'domain': 'x'}), '');
    });
  });
}
