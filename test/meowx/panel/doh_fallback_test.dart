import 'package:bett_box/meowx/panel/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DoH 应答解析', () {
    test('取第一个 A 记录', () {
      final body = {
        'Status': 0,
        'Answer': [
          {'name': 'panel.example.com', 'type': 5, 'TTL': 60, 'data': 'x.cdn.example.'},
          {'name': 'x.cdn.example', 'type': 1, 'TTL': 60, 'data': '104.26.10.2'},
          {'name': 'x.cdn.example', 'type': 1, 'TTL': 60, 'data': '172.67.70.180'},
        ],
      };
      expect(PanelClient.parseDohAnswer(body), '104.26.10.2');
    });

    test('只有 CNAME / AAAA / 空应答 → null', () {
      expect(PanelClient.parseDohAnswer({'Status': 3}), isNull);
      expect(PanelClient.parseDohAnswer({'Answer': []}), isNull);
      expect(
        PanelClient.parseDohAnswer({
          'Answer': [
            {'type': 5, 'data': 'x.example.'},
            {'type': 28, 'data': '2606:4700::1'},
          ],
        }),
        isNull,
      );
    });

    test('data 不是合法 IP → 跳过', () {
      expect(
        PanelClient.parseDohAnswer({
          'Answer': [
            {'type': 1, 'data': 'not-an-ip'},
            {'type': 1, 'data': '1.2.3.4'},
          ],
        }),
        '1.2.3.4',
      );
    });

    test('整个 body 不是 Map / Answer 不是 List → null', () {
      expect(PanelClient.parseDohAnswer('nope'), isNull);
      expect(PanelClient.parseDohAnswer({'Answer': 'nope'}), isNull);
    });
  });
}
