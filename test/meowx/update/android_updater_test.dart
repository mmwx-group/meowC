import 'dart:io';
import 'dart:math';

import 'package:bett_box/meowx/update/android_updater.dart';
import 'package:bett_box/meowx/update/update_manifest.dart';
import 'package:bett_box/meowx/update/windows_updater.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 本地起一个只回这段字节的 HTTP 服务，记下被请求了几次。
Future<(HttpServer, List<int>)> _serve(List<int> bytes) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final hits = <int>[0];
  server.listen((req) async {
    hits[0]++;
    req.response.headers.contentType = ContentType.binary;
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  });
  return (server, hits);
}

UpdateFile _apk(List<int> bytes, HttpServer server, {String name = 'MeowX-9.9.9-android-arm64-v8a.apk', String? sha}) =>
    UpdateFile(
      kind: 'apk',
      name: name,
      url: 'http://127.0.0.1:${server.port}/$name',
      size: bytes.length,
      sha256: sha ?? sha256.convert(bytes).toString(),
    );

void main() {
  late Directory tmp;
  final bytes = List<int>.generate(50000, (i) => Random(7).nextInt(256));

  setUp(() async => tmp = await Directory.systemTemp.createTemp('android_updater_test'));
  tearDown(() async => tmp.delete(recursive: true));

  AndroidUpdater updater(List<String> installed, {ApkInstallResult result = ApkInstallResult.launched}) => AndroidUpdater(
    workRoot: tmp.path,
    isTrusted: (_) => true,
    install: (path) async {
      installed.add(path);
      return result;
    },
  );

  test('下载校验通过 → 交给安装器，进度最后是 launching；同名的已校验包再点一次不重下，别的旧包清掉', () async {
    final (server, hits) = await _serve(bytes);
    addTearDown(server.close);
    final stale = File(p.join(tmp.path, AndroidUpdater.dirName, 'MeowX-0.0.1-android-arm64-v8a.apk'));
    await stale.create(recursive: true);
    final installed = <String>[];
    final progress = ValueNotifier(UpdateProgress.zero);
    final file = _apk(bytes, server);

    await updater(installed).run(file, progress: progress);
    expect(installed, [p.join(tmp.path, AndroidUpdater.dirName, file.name)]);
    expect(await File(installed.single).readAsBytes(), bytes);
    expect(progress.value.stage, UpdateStage.launching);
    expect(await stale.exists(), isFalse);

    await updater(installed).run(file, progress: ValueNotifier(UpdateProgress.zero));
    expect(hits[0], 1);
    expect(installed.length, 2);
  });

  test('缓存里同名但内容不对的包删掉重下', () async {
    final (server, hits) = await _serve(bytes);
    addTearDown(server.close);
    final file = _apk(bytes, server);
    final bad = File(p.join(tmp.path, AndroidUpdater.dirName, file.name));
    await bad.create(recursive: true);
    await bad.writeAsBytes(bytes.sublist(0, 1000));   // 下到半截的包
    final installed = <String>[];
    await updater(installed).run(file, progress: ValueNotifier(UpdateProgress.zero));
    expect(hits[0], 1);
    expect(await File(installed.single).readAsBytes(), bytes);
  });

  test('哈希不符 → UpdateError，不调安装器、不留文件', () async {
    final (server, _) = await _serve(bytes);
    addTearDown(server.close);
    final installed = <String>[];
    await expectLater(
      updater(installed).run(_apk(bytes, server, sha: 'ab' * 32), progress: ValueNotifier(UpdateProgress.zero)),
      throwsA(isA<UpdateError>()),
    );
    expect(installed, isEmpty);
    expect(await Directory(p.join(tmp.path, AndroidUpdater.dirName)).list().toList(), isEmpty);
  });

  test('没允许「安装未知应用」→ ApkInstallPermissionNeeded 带着校验过的包；安装器调不起 → UpdateError', () async {
    final (server, _) = await _serve(bytes);
    addTearDown(server.close);
    final file = _apk(bytes, server);
    final installed = <String>[];
    try {
      await updater(installed, result: ApkInstallResult.needsPermission).run(file, progress: ValueNotifier(UpdateProgress.zero));
      fail('应抛 ApkInstallPermissionNeeded');
    } on ApkInstallPermissionNeeded catch (e) {
      expect(await e.apk.readAsBytes(), bytes);
      await updater(installed).launch(e.apk);   // 开完开关回来「继续安装」
      expect(installed.last, e.apk.path);
    }
    await expectLater(updater(installed, result: ApkInstallResult.failed).launch(File(installed.last)), throwsA(isA<UpdateError>()));
  });

  test('只认 apk、只认受信任的地址', () async {
    final apk = UpdateFile(kind: 'apk', name: 'a.apk', url: 'https://evil.example.com/a.apk', size: 1, sha256: 'ab' * 32);
    final real = AndroidUpdater(workRoot: tmp.path, install: (_) async => ApkInstallResult.launched);
    await expectLater(real.run(apk, progress: ValueNotifier(UpdateProgress.zero)), throwsA(isA<UpdateError>()));
    final setup = UpdateFile(kind: 'setup', name: 'a.exe', url: apk.url, size: 1, sha256: apk.sha256);
    await expectLater(real.run(setup, progress: ValueNotifier(UpdateProgress.zero)), throwsA(isA<UpdateError>()));
    expect(ApkInstallResult.parse('ok'), ApkInstallResult.launched);
    expect(ApkInstallResult.parse('permission'), ApkInstallResult.needsPermission);
    expect(ApkInstallResult.parse(null), ApkInstallResult.failed);
  });
}
