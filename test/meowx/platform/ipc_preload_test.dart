import 'dart:isolate';
import 'dart:ui';

import 'package:bett_box/clash/lib.dart';
import 'package:bett_box/common/constant.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android 上 main() 在 runApp 之前等 ClashLib.preload()：服务引擎把端口发回来才算就绪。
/// 这里没有服务引擎，等同于「它迟迟不来」，再手动把端口送进主 isolate 的接收口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('第一次 2 秒没等到端口之后才连上：早先拿到的 preload() 仍然会完成', () async {
    final lib = ClashLib();
    var ready = false;
    final preload = lib.preload().then((ok) {
      ready = true;
      return ok;
    });

    // 越过 _waitForIpc 的第一次超时。以前超时后会把还没完成的 Completer 换掉，
    // 这个 future 从此没人完成——main() 就停死在启动页。
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    expect(ready, isFalse);

    final servicePort = ReceivePort();
    addTearDown(servicePort.close);
    IsolateNameServer.lookupPortByName(mainIsolate)!.send(servicePort.sendPort);

    expect(await preload.timeout(const Duration(seconds: 2)), isTrue);
    expect(lib.sendPort, isNotNull);
  });
}
