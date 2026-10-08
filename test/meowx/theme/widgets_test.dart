import 'package:bett_box/meowx/theme/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('regionCode', () {
    test('国旗 emoji 优先', () {
      expect(regionCode('🇭🇰 香港 01 · IEPL'), 'HK');
      expect(regionCode('🇯🇵 美国中转'), 'JP');
    });

    test('中英文地名', () {
      expect(regionCode('香港 01'), 'HK');
      expect(regionCode('东京-家宽'), 'JP');
      expect(regionCode('Los Angeles 02'), 'US');
      expect(regionCode('德国 法兰克福'), 'DE');
    });

    test('多个地名取最先出现的', () {
      expect(regionCode('日本 → 美国'), 'JP');
    });

    test('独立的两位大写码，UK 归到 GB', () {
      expect(regionCode('IEPL-SG-03'), 'SG');
      expect(regionCode('UK 01'), 'GB');
      // 嵌在单词里的不算
      expect(regionCode('BUSY node'), isNull);
    });

    test('猜不出返回 null', () {
      expect(regionCode('自动选择'), isNull);
      expect(regionCode('DIRECT'), isNull);
      expect(regionCode(''), isNull);
    });
  });

  group('stripFlag', () {
    test('去掉开头的国旗和空白', () {
      expect(stripFlag('🇭🇰 香港 01'), '香港 01');
      expect(stripFlag('🇭🇰🇨🇳香港'), '香港');
    });

    test('没有国旗 / 国旗不在开头时原样返回', () {
      expect(stripFlag('香港 01'), '香港 01');
      expect(stripFlag('香港 🇭🇰'), '香港 🇭🇰');
    });
  });
}
