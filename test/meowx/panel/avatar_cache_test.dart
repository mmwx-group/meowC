import 'dart:io';
import 'dart:typed_data';

import 'package:bett_box/meowx/panel/avatar_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// 头像本地缓存：下过一次就从磁盘读（换个进程 = 新的 AvatarCache 也不再请求），换地址才重新下、只留最新一张
void main() {
  late Directory dir;
  var fetches = <String>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('avatar');
    fetches = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AvatarCache make({bool fail = false}) => AvatarCache(
    dir: () async => dir.path,
    fetch: (url) async {
      fetches.add(url);
      if (fail) throw const SocketException('offline');
      return Uint8List.fromList(url.codeUnits);
    },
  );

  test('下一次之后同一地址走内存 / 磁盘，不再请求', () async {
    final a = make();
    expect(await a.load('https://h/a?v=1'), isNotNull);
    expect(await a.load('https://h/a?v=1'), isNotNull);
    expect(fetches, ['https://h/a?v=1']);

    final b = make(fail: true); // 新进程、离线
    expect(String.fromCharCodes((await b.load('https://h/a?v=1'))!), 'https://h/a?v=1');
    expect(fetches, ['https://h/a?v=1']);
  });

  test('换头像地址重新下，旧文件删掉', () async {
    final a = make();
    await a.load('https://h/a?v=1');
    await a.load('https://h/a?v=2');
    expect(fetches, ['https://h/a?v=1', 'https://h/a?v=2']);
    expect(dir.listSync().whereType<File>().length, 1);
    expect(a.peek('https://h/a?v=1'), isNull);
  });

  test('下载失败返回 null，下次再试', () async {
    expect(await make(fail: true).load('https://h/b'), isNull);
    expect(await make().load('https://h/b'), isNotNull);
    expect(fetches.length, 2);
  });
}
