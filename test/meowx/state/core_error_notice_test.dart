import 'package:bett_box/meowx/state/core_error_notice.dart';
// fake_async 随 flutter_test 一起来（SDK 钉的版本），不单独写进 pubspec
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const err1 = 'initial proxy provider Airport_01 error: Get "%E8%AE%A2%E9%98%85%E9%93%BE%E6%8E%A51": unsupported protocol scheme ""';
  const err2 = 'initial proxy provider Airport_02 error: Get "%E8%AE%A2%E9%98%85%E9%93%BE%E6%8E%A52": unsupported protocol scheme ""';
  const err3 = 'initial proxy provider Airport_03 error: Get "%E8%AE%A2%E9%98%85%E9%93%BE%E6%8E%A53": unsupported protocol scheme ""';

  test('三个节点集地址没填：合成一条中文提示（带解码后的占位文字），不再逐条弹英文', () {
    fakeAsync((async) {
      final shown = <String>[];
      final n = CoreErrorNotice(show: shown.add);
      n.onError(err1);
      n.onError(err3);
      n.onError(err2);
      expect(shown, isEmpty, reason: '先攒着');
      async.elapse(const Duration(seconds: 1));
      expect(shown, hasLength(1));
      expect(shown.single, contains('节点集 Airport_01、Airport_02、Airport_03'));
      expect(shown.single, contains('没有填有效的链接'));
      expect(shown.single, contains('「订阅链接1」'));
      expect(shown.single, isNot(contains('%E8')));

      // 同一批（重连 / 重起内核）本次运行不再提示
      n.onError(err1);
      n.onError(err2);
      n.onError(err3);
      async.elapse(const Duration(seconds: 1));
      expect(shown, hasLength(1));
    });
  });

  test('别的原因的加载失败只报名字、指到日志；超过三个写「等 N 个」；规则集与节点集各一条', () {
    fakeAsync((async) {
      final shown = <String>[];
      final n = CoreErrorNotice(show: shown.add);
      for (final name in ['a', 'b', 'c', 'd']) {
        n.onError('initial proxy provider $name error: context deadline exceeded');
      }
      n.onError('initial rule provider reject error: 404 Not Found');
      async.elapse(const Duration(seconds: 1));
      expect(shown, hasLength(2));
      expect(shown[0], '订阅里的节点集 a、b、c 等 4 个 加载失败，已跳过。详情见「动态 › 日志」');
      expect(shown[1], contains('规则集 reject'));
    });
  });

  test('其它内核报错原样提示，同一条 10 秒内不重复', () {
    var now = DateTime(2026, 11, 20, 12);
    final shown = <String>[];
    final n = CoreErrorNotice(show: shown.add, now: () => now);
    const bind = 'Start Mixed(http+socks) server error: listen tcp 127.0.0.1:7890: bind: address already in use';
    n.onError(bind);
    n.onError(bind);
    expect(shown, [bind]);
    now = now.add(const Duration(seconds: 11));
    n.onError(bind);
    expect(shown, [bind, bind]);
    n.onError('  ');
    expect(shown, hasLength(2));
  });

  test('占位文字：解码百分号编码；太长或取不到就不显示', () {
    expect(CoreErrorNotice.placeholderOf('Get "%E8%AE%A2%E9%98%85%E9%93%BE%E6%8E%A51": unsupported protocol scheme ""'), '订阅链接1');
    expect(CoreErrorNotice.placeholderOf('unsupported protocol scheme'), isNull);
    expect(CoreErrorNotice.placeholderOf('Get "${'x' * 60}": unsupported protocol scheme ""'), isNull);
  });
}
