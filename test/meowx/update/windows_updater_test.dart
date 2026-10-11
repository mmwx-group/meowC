import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bett_box/meowx/update/update_manifest.dart';
import 'package:bett_box/meowx/update/windows_updater.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _waitFn = '''
function Wait-AppExit {
  for (\$i = 0; \$i -lt 200; \$i++) {
    if (-not (Get-Process -Id \$AppPid -ErrorAction SilentlyContinue)) { return \$true }
    Start-Sleep -Milliseconds 300
  }
  return \$false
}
''';

const _abortIfRunning = '''
if (-not (Wait-AppExit)) {
  Add-Content -Path \$Log -Value 'app still running after 60s, abort'
  exit 1
}
''';

/// 本地起一个只回这段字节的 HTTP 服务；[chunkDelay] 用来制造慢下载好测取消。
Future<HttpServer> _serve(List<int> bytes, {Duration? chunkDelay}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    try {
      req.response.headers.contentType = ContentType.binary;
      req.response.contentLength = bytes.length;
      for (var i = 0; i < bytes.length; i += 1024) {
        req.response.add(bytes.sublist(i, min(i + 1024, bytes.length)));
        await req.response.flush();
        if (chunkDelay != null) await Future.delayed(chunkDelay);
      }
      await req.response.close();
    } catch (_) {
      // 客户端取消后连接被关，这里的写失败是预期的
    }
  });
  return server;
}

UpdateFile _fileFor(List<int> bytes, HttpServer server, {int? size, String? sha, String name = 'pkg.bin'}) => UpdateFile(
  kind: 'setup',
  name: name,
  url: 'http://127.0.0.1:${server.port}/$name',
  size: size ?? bytes.length,
  sha256: sha ?? sha256.convert(bytes).toString(),
);

/// 不走网络的 Dio 适配器：按 URL 回固定字节，让 WindowsUpdater.run 能用发布域名的 https 地址跑通整条链路。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes);

  final Map<String, List<int>> routes;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final bytes = routes[options.uri.toString()];
    if (bytes == null) return ResponseBody.fromBytes(Uint8List(0), 404);
    return ResponseBody.fromBytes(
      Uint8List.fromList(bytes),
      200,
      headers: {
        'content-length': ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('meowx-updater-test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('脚本生成', () {
    test('便携版脚本内容精确匹配（含单引号转义、中文路径、进程名列表）', () {
      final script = buildPortableUpdaterScript(
        pid: 4242,
        appDir: r"C:\Apps\Meow's X",
        stagingDir: r'C:\Users\小明\AppData\Local\Temp\meowx-update-1\stage\MeowX',
        exeName: 'MeowX.exe',
        serviceName: 'MeowXHelperService',
        killProcessNames: const ['MeowXCore', 'MeowXHelperService', 'MeowX'],
      );
      expect(script, '''
# MeowX 便携版更新脚本：由 App 生成，跑完自删
param([switch]\$Elevated)
\$ErrorActionPreference = 'Continue'
\$Self = \$MyInvocation.MyCommand.Path
\$Work = Split-Path -Parent \$Self
Set-Content -LiteralPath (Join-Path \$Work 'started') -Value 1
\$AppPid = 4242
\$AppDir = 'C:\\Apps\\Meow''s X'
\$Staging = 'C:\\Users\\小明\\AppData\\Local\\Temp\\meowx-update-1\\stage\\MeowX'
\$ExeName = 'MeowX.exe'
\$ServiceName = 'MeowXHelperService'
\$Log = Join-Path \$Work 'update.log'
\$Result = Join-Path \$Work 'result.txt'

$_waitFn
function Invoke-Update {
  Start-Transcript -Path \$Log -Append | Out-Null
  \$wasRunning = \$false
  \$svc = Get-Service -Name \$ServiceName -ErrorAction SilentlyContinue
  if (\$svc) {
    \$wasRunning = (\$svc.Status -eq 'Running')
    Stop-Service -Name \$ServiceName -Force -ErrorAction SilentlyContinue
  }
  \$prefix = \$AppDir.TrimEnd([char]'\\') + '\\'
  Get-Process -Name 'MeowXCore', 'MeowXHelperService', 'MeowX' -ErrorAction SilentlyContinue | Where-Object { \$_.Path -and \$_.Path.StartsWith(\$prefix, [System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
  robocopy \$Staging \$AppDir /E /R:5 /W:1 /NP /NFL /NDL /XF portable
  \$rc = \$LASTEXITCODE
  if (\$wasRunning) { Start-Service -Name \$ServiceName -ErrorAction SilentlyContinue }
  Stop-Transcript | Out-Null
  if (\$rc -ge 8) { Set-Content -LiteralPath \$Result -Value \$rc } else { Set-Content -LiteralPath \$Result -Value 0 }
}

if (\$Elevated) {
  Invoke-Update
  exit 0
}

$_abortIfRunning
\$needElevate = \$false
if (Get-Service -Name \$ServiceName -ErrorAction SilentlyContinue) {
  \$needElevate = \$true
} else {
  try {
    \$probe = Join-Path \$AppDir ('.meowx-write-test-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText(\$probe, '')
    [IO.File]::Delete(\$probe)
  } catch {
    \$needElevate = \$true
  }
}
\$code = -1
if (\$needElevate) {
  try {
    Start-Process -FilePath (Join-Path \$PSHOME 'powershell.exe') -Verb RunAs -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + \$Self + '"'), '-Elevated')
  } catch {
    Add-Content -Path \$Log -Value ('elevation failed: ' + \$_)
  }
} else {
  Invoke-Update
}
if (Test-Path -LiteralPath \$Result) { \$code = [int](Get-Content -LiteralPath \$Result) }
Start-Process -FilePath (Join-Path \$AppDir \$ExeName) -WorkingDirectory \$AppDir
if (\$code -eq 0) {
  Remove-Item -LiteralPath \$Work -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show(('MeowX 更新未完成（代码 ' + \$code + '），已按原版本启动。详情见 ' + \$Log), 'MeowX', 'OK', 'Warning') | Out-Null
}
exit 0
''');
      // 便携版用户数据与 Flutter 的 data\\ 同目录：只能增量覆盖，绝不能 /MIR /PURGE
      expect(script, isNot(contains('/MIR')));
      expect(script, isNot(contains('/PURGE')));
      // started 标记必须在等 App 退出之前写；不再无条件提权、不再全机杀同名进程
      expect(script.indexOf("Join-Path \$Work 'started'"), lessThan(script.indexOf('Wait-AppExit')));
      expect(script, isNot(contains('Stop-Process -Name')));
    });

    test('安装版脚本内容精确匹配（Inno 静默参数 + 退出码判定 + 自行重启 App）', () {
      final script = buildSetupUpdaterScript(
        pid: 4242,
        installerPath: r'C:\Users\小明\AppData\Local\Temp\meowx-update-1\MeowX-0.1.3-windows-amd64-setup.exe',
        exePath: r'C:\Program Files\MeowX\MeowX.exe',
      );
      expect(script, '''
# MeowX 安装版更新脚本：由 App 生成，跑完自删
\$ErrorActionPreference = 'Continue'
\$Self = \$MyInvocation.MyCommand.Path
\$Work = Split-Path -Parent \$Self
Set-Content -LiteralPath (Join-Path \$Work 'started') -Value 1
\$AppPid = 4242
\$Installer = 'C:\\Users\\小明\\AppData\\Local\\Temp\\meowx-update-1\\MeowX-0.1.3-windows-amd64-setup.exe'
\$Exe = 'C:\\Program Files\\MeowX\\MeowX.exe'
\$Log = Join-Path \$Work 'update.log'

$_waitFn
$_abortIfRunning
\$code = -1
try {
  \$proc = Start-Process -FilePath \$Installer -ArgumentList @('/SILENT', '/SP-', '/NORESTART', '/CLOSEAPPLICATIONS') -Wait -PassThru
  if (\$null -ne \$proc.ExitCode) { \$code = \$proc.ExitCode }
} catch {
  Add-Content -Path \$Log -Value ('installer failed: ' + \$_)
}
if (\$code -ne 0) { Add-Content -Path \$Log -Value ('installer exit code: ' + \$code) }
Start-Process -FilePath \$Exe -WorkingDirectory (Split-Path -Parent \$Exe)
if (\$code -eq 0) {
  Remove-Item -LiteralPath \$Work -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show(('MeowX 安装未完成（代码 ' + \$code + '），已按原版本启动。详情见 ' + \$Log), 'MeowX', 'OK', 'Warning') | Out-Null
}
exit 0
''');
    });

    test('PowerShell 用 SystemRoot 下的绝对路径，不查 PATH', () {
      expect(powerShellPath({'SystemRoot': r'D:\Win'}), r'D:\Win\System32\WindowsPowerShell\v1.0\powershell.exe');
      expect(powerShellPath({}), r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
    });

    test('拉起命令：Start-Process 另起带隐藏控制台的 PowerShell，脚本路径包双引号、单引号转义', () {
      final command = updaterLaunchCommand(r"C:\Users\O'Neil Zhu\AppData\Local\Temp\meowx-update-1\update.ps1", powerShell: r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
      expect(command, startsWith(r"Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -WindowStyle Hidden -ArgumentList @("));
      expect(command, contains("'-File',('\"' + 'C:\\Users\\O''Neil Zhu\\AppData\\Local\\Temp\\meowx-update-1\\update.ps1' + '\"'))"));
      // 不能再带 Dart 的 detached（没有控制台，PowerShell 5.1 起不来）：命令里必须是 Start-Process
      expect(command, isNot(contains('-NoNewWindow')));
    });

    // 只在 Windows 上跑（CI 的 updater-windows 任务）：真的起 PowerShell，看脚本写不写得出 started 标记。
    // 桩测不出「PowerShell 根本没起来」——0.2.4 及以前真机上一直报「更新脚本未能启动」就是这么漏掉的。
    test('真实拉起：路径带空格和中文，脚本写得出 started 标记', () async {
      Future<(Directory, File)> prepare() async {
        final dir = await Directory.systemTemp.createTemp('meowx updater 测试 ');
        addTearDown(() async {
          try {
            await dir.delete(recursive: true);
          } catch (_) {}
        });
        final script = File('${dir.path}${Platform.pathSeparator}update.ps1');
        const body = '\$Work = Split-Path -Parent \$MyInvocation.MyCommand.Path\r\n'
            "Set-Content -LiteralPath (Join-Path \$Work '$updaterStartedMarker') -Value 1\r\n";
        await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(body)]);
        return (dir, script);
      }

      final (dir, script) = await prepare();
      await launchUpdaterScript(script);
      final started = await waitForFile(File('${dir.path}${Platform.pathSeparator}$updaterStartedMarker'), timeout: const Duration(seconds: 40));
      expect(started, isTrue, reason: 'Start-Process 另起的 PowerShell 没有写出 started 标记');

      // 对照（只打印不断言）：以前的办法——Dart 的 detached 直接起 PowerShell，子进程没有控制台
      final (oldDir, oldScript) = await prepare();
      await Process.start(
        powerShellPath(),
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', oldScript.path],
        mode: ProcessStartMode.detached,
      );
      final oldStarted = await waitForFile(File('${oldDir.path}${Platform.pathSeparator}$updaterStartedMarker'), timeout: const Duration(seconds: 20));
      // ignore: avoid_print
      print('对照：detached 直接起 PowerShell → started=$oldStarted');
    }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));

    test('EncodedCommand：UTF-16LE + base64，中文路径原样往返', () {
      const command = r"Start-Process 'C:\用户\临时\update.ps1'";
      final bytes = base64.decode(encodePowerShellCommand(command));
      expect(bytes.length, command.codeUnits.length * 2);
      final units = [for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
      expect(String.fromCharCodes(units), command);
    });
  });

  group('校验', () {
    test('size + sha256 都对 → 通过', () async {
      final bytes = List<int>.generate(5000, (i) => i * 7 % 256);
      final f = File(p.join(tmp.path, 'a.bin'))..writeAsBytesSync(bytes);
      await verifyUpdateFile(f, UpdateFile(kind: 'setup', name: 'a.bin', url: 'x', size: 5000, sha256: sha256.convert(bytes).toString()));
    });

    test('大小不符 / 哈希不符 / 清单缺 sha256 → UpdateError', () async {
      final bytes = List<int>.generate(5000, (i) => i * 7 % 256);
      final f = File(p.join(tmp.path, 'a.bin'))..writeAsBytesSync(bytes);
      final sha = sha256.convert(bytes).toString();
      expect(
        () => verifyUpdateFile(f, UpdateFile(kind: 'setup', name: 'a.bin', url: 'x', size: 4999, sha256: sha)),
        throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('大小'))),
      );
      expect(
        () => verifyUpdateFile(f, UpdateFile(kind: 'setup', name: 'a.bin', url: 'x', size: 5000, sha256: 'ab' * 32)),
        throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('SHA-256'))),
      );
      expect(
        () => verifyUpdateFile(f, UpdateFile(kind: 'setup', name: 'a.bin', url: 'x', size: 5000, sha256: '')),
        throwsA(isA<UpdateError>()),
      );
    });
  });

  group('下载（默认走 strictUpdateDio，本机地址直连）', () {
    final bytes = List<int>.generate(70 * 1024 + 123, (i) => (i * 31 + 7) % 256);

    test('流式落盘 + 边下边算 sha256；进度到 100%', () async {
      final server = await _serve(bytes);
      addTearDown(server.close);
      final progress = ValueNotifier(UpdateProgress.zero);
      final file = await downloadUpdateFile(_fileFor(bytes, server), dir: tmp.path, progress: progress);
      expect(file.path, p.join(tmp.path, 'pkg.bin'));
      expect(file.readAsBytesSync(), bytes);
      expect(progress.value.stage, UpdateStage.downloading);
      expect(progress.value.received, bytes.length);
      expect(progress.value.total, bytes.length);
      expect(progress.value.fraction, 1.0);
    });

    test('sha256 不符 → 抛错并删掉文件', () async {
      final server = await _serve(bytes);
      addTearDown(server.close);
      await expectLater(
        downloadUpdateFile(_fileFor(bytes, server, sha: 'cd' * 32), dir: tmp.path),
        throwsA(isA<UpdateError>()),
      );
      expect(File(p.join(tmp.path, 'pkg.bin')).existsSync(), isFalse);
    });

    test('大小不符 → 抛错并删掉文件', () async {
      final server = await _serve(bytes);
      addTearDown(server.close);
      await expectLater(
        downloadUpdateFile(_fileFor(bytes, server, size: bytes.length + 1), dir: tmp.path),
        throwsA(isA<UpdateError>()),
      );
      expect(File(p.join(tmp.path, 'pkg.bin')).existsSync(), isFalse);
    });

    test('下载中取消 → UpdateCancelled，半成品删掉', () async {
      final server = await _serve(bytes, chunkDelay: const Duration(milliseconds: 20));
      addTearDown(server.close);
      final progress = ValueNotifier(UpdateProgress.zero);
      final cancel = CancelToken();
      progress.addListener(() {
        if (progress.value.received > 0 && !cancel.isCancelled) cancel.cancel();
      });
      await expectLater(
        downloadUpdateFile(_fileFor(bytes, server), dir: tmp.path, progress: progress, cancelToken: cancel),
        throwsA(isA<UpdateCancelled>()),
      );
      expect(File(p.join(tmp.path, 'pkg.bin')).existsSync(), isFalse);
    });

    test('token 已取消 + 冒出来的不是取消类错误 → 仍按 UpdateCancelled', () async {
      final cancel = CancelToken();
      // 适配器先取消 token 再抛普通 StateError（Dio 会包成 type=unknown 的 DioException，不是 cancel 类型）
      final dio = Dio()..httpClientAdapter = _ThrowingAdapter(cancel.cancel);
      await expectLater(
        downloadUpdateFile(
          const UpdateFile(kind: 'setup', name: 'pkg.bin', url: 'https://dl.miaomiaowux.com/x', size: 1, sha256: 'ab'),
          dir: tmp.path,
          cancelToken: cancel,
          dio: dio,
        ),
        throwsA(isA<UpdateCancelled>()),
      );
    });
  });

  group('便携包目录定位', () {
    test('根目录就有主程序', () {
      File(p.join(tmp.path, 'MeowX.exe')).writeAsStringSync('');
      expect(resolveStagedAppDir(tmp, 'MeowX.exe').path, tmp.path);
    });

    test('CI 的 Compress-Archive 多包一层 MeowX/', () {
      final inner = Directory(p.join(tmp.path, 'MeowX'))..createSync();
      File(p.join(inner.path, 'MeowX.exe')).writeAsStringSync('');
      expect(resolveStagedAppDir(tmp, 'MeowX.exe').path, inner.path);
    });

    test('找不到主程序 → UpdateError', () {
      Directory(p.join(tmp.path, 'a')).createSync();
      Directory(p.join(tmp.path, 'b')).createSync();
      expect(() => resolveStagedAppDir(tmp, 'MeowX.exe'), throwsA(isA<UpdateError>()));
    });
  });

  group('waitForFile', () {
    test('时限内出现 → true', () async {
      final f = File(p.join(tmp.path, 'started'));
      Future.delayed(const Duration(milliseconds: 150), () => f.writeAsStringSync('1'));
      expect(await waitForFile(f, timeout: const Duration(seconds: 3), interval: const Duration(milliseconds: 20)), isTrue);
    });

    test('一直不出现 → 超时 false', () async {
      final f = File(p.join(tmp.path, 'started'));
      expect(await waitForFile(f, timeout: const Duration(milliseconds: 200), interval: const Duration(milliseconds: 20)), isFalse);
    });
  });

  group('WindowsUpdater.run', () {
    final bytes = List<int>.generate(4096, (i) => (i * 13 + 5) % 256);
    const url = 'https://dl.miaomiaowux.com/meowx/windows/MeowX-9.9.9-windows-amd64-setup.exe';
    UpdateFile trusted() => UpdateFile(
      kind: 'setup',
      name: 'MeowX-9.9.9-windows-amd64-setup.exe',
      url: url,
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    Dio fakeDio() => Dio()..httpClientAdapter = _FakeAdapter({url: bytes});
    Directory workDir() => tmp.listSync().whereType<Directory>().single;

    test('脚本写出 started 标记 → 退出 App；脚本带 BOM、标记在工作目录', () async {
      var exited = 0;
      File? launched;
      final updater = WindowsUpdater(
        workRoot: tmp.path,
        exitApp: () async => exited++,
        dio: fakeDio(),
        launch: (script) async {
          launched = script;
          File(p.join(script.parent.path, updaterStartedMarker)).writeAsStringSync('1');
        },
        startTimeout: const Duration(seconds: 3),
      );
      final progress = ValueNotifier(UpdateProgress.zero);
      await updater.run(trusted(), progress: progress);
      expect(exited, 1);
      expect(progress.value.stage, UpdateStage.launching);
      expect(launched!.path, p.join(workDir().path, 'update.ps1'));
      expect(launched!.readAsBytesSync().sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(File(p.join(workDir().path, 'MeowX-9.9.9-windows-amd64-setup.exe')).readAsBytesSync(), bytes);
    });

    test('标记没出现 → 不退出 App、保留下载包、UpdateError', () async {
      var exited = 0;
      final updater = WindowsUpdater(
        workRoot: tmp.path,
        exitApp: () async => exited++,
        dio: fakeDio(),
        launch: (_) async {},
        startTimeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        updater.run(trusted(), progress: ValueNotifier(UpdateProgress.zero)),
        throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('未能启动'))),
      );
      expect(exited, 0);
      expect(File(p.join(workDir().path, 'MeowX-9.9.9-windows-amd64-setup.exe')).readAsBytesSync(), bytes);
    });

    test('拉起本身抛错 → 同样不退出、保留包、错误里带原因', () async {
      var exited = 0;
      final updater = WindowsUpdater(
        workRoot: tmp.path,
        exitApp: () async => exited++,
        dio: fakeDio(),
        launch: (_) async => throw const ProcessException('powershell.exe', [], 'blocked', 2),
        startTimeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        updater.run(trusted(), progress: ValueNotifier(UpdateProgress.zero)),
        throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('blocked'))),
      );
      expect(exited, 0);
      expect(workDir().existsSync(), isTrue);
    });

    test('http / 外域地址 → 下载都不发起，UpdateError', () async {
      var launched = 0;
      final updater = WindowsUpdater(
        workRoot: tmp.path,
        exitApp: () async {},
        dio: fakeDio(),
        launch: (_) async => launched++,
      );
      for (final bad in ['http://dl.miaomiaowux.com/meowx/windows/a.exe', 'https://dl.example/meowx/windows/a.exe']) {
        await expectLater(
          updater.run(
            UpdateFile(kind: 'setup', name: 'a.exe', url: bad, size: bytes.length, sha256: sha256.convert(bytes).toString()),
            progress: ValueNotifier(UpdateProgress.zero),
          ),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('不受信任'))),
        );
      }
      expect(launched, 0);
      expect(tmp.listSync(), isEmpty);
    });

    test('下载校验失败 → 工作目录整个清掉', () async {
      final updater = WindowsUpdater(workRoot: tmp.path, exitApp: () async {}, dio: fakeDio(), launch: (_) async {});
      final bad = UpdateFile(kind: 'setup', name: 'a.exe', url: url, size: bytes.length, sha256: 'ab' * 32);
      await expectLater(
        updater.run(bad, progress: ValueNotifier(UpdateProgress.zero)),
        throwsA(isA<UpdateError>()),
      );
      expect(tmp.listSync(), isEmpty);
    });
  });
}

class _ThrowingAdapter implements HttpClientAdapter {
  _ThrowingAdapter(this.beforeThrow);

  final void Function() beforeThrow;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    beforeThrow();
    throw StateError('boom');
  }

  @override
  void close({bool force = false}) {}
}
