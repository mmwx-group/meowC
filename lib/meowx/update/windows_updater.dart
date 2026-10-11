/// Windows 一键更新的纯逻辑部分：下载 + 流式 SHA-256 校验、便携包解压定位、更新脚本生成、拉起脚本并退出 App。
/// 界面在 update_dialog.dart；这里不碰 globalState，只靠 ValueNotifier 报进度、退出 / 拉起脚本走注入的回调，便于单测。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:bett_box/common/identity.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'update_http.dart';
import 'update_manifest.dart';

enum UpdateStage { downloading, extracting, launching }

@immutable
class UpdateProgress {
  final UpdateStage stage;
  final int received;
  final int total;

  const UpdateProgress(this.stage, this.received, this.total);

  static const zero = UpdateProgress(UpdateStage.downloading, 0, 0);

  /// 0–1；总量未知时 null（进度条转圈）。
  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

/// 用户点了取消。
class UpdateCancelled implements Exception {}

/// 更新流程里可直接展示给用户的错误。
class UpdateError implements Exception {
  final String message;

  UpdateError(this.message);

  @override
  String toString() => message;
}

/// 收 sha256 分块结果的最小 Sink（不引 package:convert 的 AccumulatorSink）。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

void _check(int size, String digest, UpdateFile expected) {
  if (expected.size > 0 && size != expected.size) {
    throw UpdateError('文件大小不符（$size / ${expected.size} 字节）');
  }
  if (expected.sha256.isEmpty) throw UpdateError('更新清单缺少 sha256，无法校验');
  if (digest != expected.sha256) throw UpdateError('文件校验不通过（SHA-256 不匹配）');
}

/// 对已在磁盘上的文件按 size + sha256 校验，不通过抛 [UpdateError]（不删文件，由调用方决定）。
Future<void> verifyUpdateFile(File file, UpdateFile expected) async {
  final digest = await sha256.bind(file.openRead()).first;
  _check(await file.length(), digest.toString(), expected);
}

bool _isCancel(Object e, CancelToken? token) =>
    token?.isCancelled == true || (e is DioException && CancelToken.isCancel(e));

/// 把包下到 [dir]（文件名取清单里的 name），边写边算 SHA-256，收完按 size + sha256 校验；
/// 校验不过或取消都删掉半成品。取消抛 [UpdateCancelled]。默认走 [strictUpdateDio]（系统证书校验）。
Future<File> downloadUpdateFile(
  UpdateFile file, {
  required String dir,
  ValueNotifier<UpdateProgress>? progress,
  CancelToken? cancelToken,
  Dio? dio,
}) async {
  final name = file.name.isNotEmpty ? file.name : (file.kind == 'portable' ? 'update.zip' : 'update.exe');
  final target = File(p.join(dir, name));
  await target.parent.create(recursive: true);

  final Response<ResponseBody> response;
  try {
    response = await (dio ?? strictUpdateDio()).get<ResponseBody>(
      file.url,
      options: Options(responseType: ResponseType.stream),
      cancelToken: cancelToken,
    );
  } catch (e) {
    if (_isCancel(e, cancelToken)) throw UpdateCancelled();
    rethrow;
  }
  final body = response.data;
  if (body == null) throw UpdateError('下载响应为空');
  final total = file.size > 0 ? file.size : int.tryParse(response.headers.value('content-length') ?? '') ?? 0;

  final sink = target.openWrite();
  final digestSink = _DigestSink();
  final hasher = sha256.startChunkedConversion(digestSink);
  var received = 0;
  var closed = false;
  try {
    await for (final chunk in body.stream) {
      if (cancelToken?.isCancelled == true) throw UpdateCancelled();
      sink.add(chunk);
      hasher.add(chunk);
      received += chunk.length;
      progress?.value = UpdateProgress(UpdateStage.downloading, received, total);
    }
    if (cancelToken?.isCancelled == true) throw UpdateCancelled();
    await sink.flush();
    await sink.close();
    closed = true;
    hasher.close();
    _check(received, digestSink.value.toString(), file);
    return target;
  } catch (e) {
    if (!closed) {
      try {
        await sink.close();
      } catch (_) {}
    }
    if (await target.exists()) await target.delete();
    // 取消时连接被掐断，冒出来的可能是 DioException 之外的 IO 错误，一律按取消处理
    if (_isCancel(e, cancelToken)) throw UpdateCancelled();
    rethrow;
  }
}

/// 便携 zip 是 CI 用 Compress-Archive 打的，里面多一层 `MeowX/`；解压后找真正装着主程序的目录（根目录或唯一子目录）。
Directory resolveStagedAppDir(Directory stage, String exeName) {
  if (File(p.join(stage.path, exeName)).existsSync()) return stage;
  final subs = stage.listSync().whereType<Directory>().toList();
  if (subs.length == 1 && File(p.join(subs.single.path, exeName)).existsSync()) return subs.single;
  throw UpdateError('压缩包里找不到 $exeName');
}

/// 脚本跑起来第一件事就在工作目录写这个标记文件；App 等到它才退出，等不到说明 PowerShell 根本没起来。
const updaterStartedMarker = 'started';

/// PowerShell 单引号字面量（内部 ' 翻倍）。
String _ps(String s) => "'${s.replaceAll("'", "''")}'";

/// 两份脚本共用的头：写 started 标记（第一件事）+ 等原 App 进程退出（最多 60s，超时返回 \$false，脚本必须放弃——
/// App 没退出就动文件 / 跑安装包只会失败并再起一个实例）。
String _scriptHead(String comment, {String? param}) => '''
# $comment
${param == null ? '' : '$param\n'}\$ErrorActionPreference = 'Continue'
\$Self = \$MyInvocation.MyCommand.Path
\$Work = Split-Path -Parent \$Self
Set-Content -LiteralPath (Join-Path \$Work ${_ps(updaterStartedMarker)}) -Value 1
''';

const _waitAppExitFunction = '''
function Wait-AppExit {
  for (\$i = 0; \$i -lt 200; \$i++) {
    if (-not (Get-Process -Id \$AppPid -ErrorAction SilentlyContinue)) { return \$true }
    Start-Sleep -Milliseconds 300
  }
  return \$false
}
''';

const _abortIfAppRunning = '''
if (-not (Wait-AppExit)) {
  Add-Content -Path \$Log -Value 'app still running after 60s, abort'
  exit 1
}
''';

/// 失败提示：脚本跑在隐藏窗口里，只能用消息框告诉用户。
String _failBox(String what) =>
    "[System.Windows.Forms.MessageBox]::Show(('MeowX $what（代码 ' + \$code + '），已按原版本启动。详情见 ' + \$Log), 'MeowX', 'OK', 'Warning') | Out-Null";

/// 便携版更新脚本（PowerShell，UTF-8 BOM 写盘）。等 App 退出后，只在需要时提权（装了 helper 服务要停 / 起它，
/// 或 App 目录写不进去）：需要就以管理员重跑自己（-Elevated）做换文件，否则直接在当前用户下换；
/// 之后以当前用户身份重启 App、成功就清掉工作目录（含脚本自己）。
/// 换文件 = 停 helper 服务 → 只杀 App 目录下的残留进程（别的目录里同名的 MeowX 不动）→ robocopy 覆盖 → 按原状态起服务。
/// robocopy /E 不带 /MIR：便携版用户数据放在 `<appdir>\data`（与 Flutter 自己的 `data\flutter_assets` 同一目录），
/// 只增改不删，用户文件天然保留；`portable` 标记文件不动。结果经 result.txt 回传，不依赖 -Verb RunAs 的 ExitCode。
String buildPortableUpdaterScript({
  required int pid,
  required String appDir,
  required String stagingDir,
  required String exeName,
  required String serviceName,
  required List<String> killProcessNames,
}) {
  final kill = killProcessNames.map(_ps).join(', ');
  return '''
${_scriptHead('MeowX 便携版更新脚本：由 App 生成，跑完自删', param: 'param([switch]\$Elevated)')}\$AppPid = $pid
\$AppDir = ${_ps(appDir)}
\$Staging = ${_ps(stagingDir)}
\$ExeName = ${_ps(exeName)}
\$ServiceName = ${_ps(serviceName)}
\$Log = Join-Path \$Work 'update.log'
\$Result = Join-Path \$Work 'result.txt'

$_waitAppExitFunction
function Invoke-Update {
  Start-Transcript -Path \$Log -Append | Out-Null
  \$wasRunning = \$false
  \$svc = Get-Service -Name \$ServiceName -ErrorAction SilentlyContinue
  if (\$svc) {
    \$wasRunning = (\$svc.Status -eq 'Running')
    Stop-Service -Name \$ServiceName -Force -ErrorAction SilentlyContinue
  }
  \$prefix = \$AppDir.TrimEnd([char]'\\') + '\\'
  Get-Process -Name $kill -ErrorAction SilentlyContinue | Where-Object { \$_.Path -and \$_.Path.StartsWith(\$prefix, [System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
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

$_abortIfAppRunning
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
  ${_failBox('更新未完成')}
}
exit 0
''';
}

/// 安装版更新脚本：等 App 退出 → 静默跑 Inno Setup 安装包（它自己的清单要求管理员，UAC 由系统弹；
/// `/SILENT` 只留进度条、`/SP-` 跳过「是否继续」、`/NORESTART` 不重启、`/CLOSEAPPLICATIONS` 让它自己关占用文件的进程；
/// 不加 `/RESTARTAPPLICATIONS`——App 在它启动前就已退出，Restart Manager 无从重启）
/// → 以当前用户身份重启 App（静默模式下 .iss 里的 [Run] postinstall 项被 skipifsilent 跳过，所以这里自己拉）。
/// 退出码非 0（Inno：2 用户取消 / 5、6、7、8 准备或安装阶段失败…；UAC 被拒则 Start-Process 抛错记 -1）
/// 就写日志、留着安装包、弹框；只有 0 才清理工作目录。
String buildSetupUpdaterScript({
  required int pid,
  required String installerPath,
  required String exePath,
}) {
  return '''
${_scriptHead('MeowX 安装版更新脚本：由 App 生成，跑完自删')}\$AppPid = $pid
\$Installer = ${_ps(installerPath)}
\$Exe = ${_ps(exePath)}
\$Log = Join-Path \$Work 'update.log'

$_waitAppExitFunction
$_abortIfAppRunning
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
  ${_failBox('安装未完成')}
}
exit 0
''';
}

/// Windows PowerShell 5.1 的绝对路径：不查 PATH，免得被同名程序劫持。
String powerShellPath([Map<String, String>? env]) {
  final root = (env ?? Platform.environment)['SystemRoot'] ?? r'C:\Windows';
  return '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
}

/// 拉起更新脚本用的 PowerShell 命令：用 `Start-Process` 再起一个**独立的、自带（隐藏）控制台**的 PowerShell 去跑脚本。
String updaterLaunchCommand(String scriptPath, {String? powerShell}) {
  final exe = _ps(powerShell ?? powerShellPath());
  // -File 后面的路径自己再包一层双引号：用户名带空格时临时目录里有空格
  return 'Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList '
      "@('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('\"' + ${_ps(scriptPath)} + '\"'))";
}

/// `powershell -EncodedCommand` 要的编码：UTF-16LE 再 base64。整条命令不经过命令行的引号规则，路径里有什么字符都不怕。
String encodePowerShellCommand(String command) {
  final bytes = <int>[];
  for (final unit in command.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return base64.encode(bytes);
}

/// 拉起更新脚本，让它脱离本进程继续跑。
///
/// 以前直接 `Process.start(powershell, …, mode: detached)`：Dart 的 detached 在 Windows 上带 `DETACHED_PROCESS`，子进程
/// **没有控制台**，而 Windows PowerShell 5.1 的宿主启动时要拿控制台输出缓冲，拿不到就当场退出——脚本一行都没跑，
/// App 等不到 started 标记，报「更新脚本未能启动」（真机上一直如此，单测里的桩发现不了）。
/// 现在分两步：先以普通方式（Dart 给的是 `CREATE_NO_WINDOW`，有一个隐藏的控制台）跑一个很短的 PowerShell，
/// 它用 `Start-Process` 起真正跑脚本的那个——新进程有自己的隐藏控制台、不继承管道，本进程退出也不受影响。
Future<void> launchUpdaterScript(File script) async {
  final result = await Process.run(
    powerShellPath(),
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encodePowerShellCommand(updaterLaunchCommand(script.path))],
  );
  if (result.exitCode != 0) {
    final detail = '${result.stderr}'.trim();
    throw ProcessException(
      'powershell.exe',
      const [],
      detail.isEmpty ? '退出码 ${result.exitCode}' : (detail.length > 300 ? detail.substring(0, 300) : detail),
      result.exitCode,
    );
  }
}

/// 轮询等 [file] 出现，[timeout] 内出现返回 true。
Future<bool> waitForFile(
  File file, {
  required Duration timeout,
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (await file.exists()) return true;
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(interval);
  }
}

/// 串起整个流程：下载 → （便携版）解压 → 写脚本 → 脱离本进程拉起 PowerShell → 等到脚本写出 started 标记
/// → 走 App 正常退出路径（停核心 / 还原系统代理）。脚本等本进程退出后再动文件。
/// 标记没等到（PowerShell 被拦 / 没起来）就不退出：留着工作目录里的包，抛 [UpdateError] 让界面报错。
class WindowsUpdater {
  final String workRoot;
  final Future<void> Function() exitApp;
  final Dio? dio;

  /// 拉起脚本的方式；单测里换成写 started 标记的桩。
  final Future<void> Function(File script) launch;

  /// 等 started 标记的时限。
  final Duration startTimeout;

  WindowsUpdater({
    required this.workRoot,
    required this.exitApp,
    this.dio,
    this.launch = launchUpdaterScript,
    this.startTimeout = const Duration(seconds: 25),   // 先后起两个 PowerShell，冷启动加上杀毒软件扫描，慢的机器上要十来秒
  });

  Future<void> run(
    UpdateFile file, {
    required ValueNotifier<UpdateProgress> progress,
    CancelToken? cancelToken,
  }) async {
    if (file.kind != 'setup' && file.kind != 'portable') {
      throw UpdateError('不支持的包类型：${file.kind}');
    }
    // pickUpdateFile 已经筛过，这里再拦一道：只从发布域名 https 下载会以管理员权限执行的东西
    if (!isTrustedUpdateUrl(file.url)) {
      throw UpdateError('更新地址不受信任：${file.url}');
    }
    final work = Directory(p.join(workRoot, 'meowx-update-${DateTime.now().millisecondsSinceEpoch}'));
    await work.create(recursive: true);
    final File scriptFile;
    try {
      final downloaded = await downloadUpdateFile(file, dir: work.path, progress: progress, cancelToken: cancelToken, dio: dio);
      final exePath = Platform.resolvedExecutable;
      final String script;
      if (file.kind == 'setup') {
        script = buildSetupUpdaterScript(pid: pid, installerPath: downloaded.path, exePath: exePath);
      } else {
        progress.value = const UpdateProgress(UpdateStage.extracting, 0, 0);
        final stage = Directory(p.join(work.path, 'stage'));
        final zipPath = downloaded.path;
        final stagePath = stage.path;
        await Isolate.run(() => extractFileToDisk(zipPath, stagePath));
        if (cancelToken?.isCancelled == true) throw UpdateCancelled();
        final exeName = p.basename(exePath);
        final staged = resolveStagedAppDir(stage, exeName);
        await downloaded.delete();
        // 停服务后再杀残留的核心 / helper / 主程序进程，文件被占用会让 robocopy 失败（同 inno_setup.iss 的 ForceKillProcesses）
        script = buildPortableUpdaterScript(
          pid: pid,
          appDir: p.dirname(exePath),
          stagingDir: staged.path,
          exeName: exeName,
          serviceName: WindowsHelperIdentity.serviceName,
          killProcessNames: [
            AppIdentity.coreExecutableName,
            WindowsHelperIdentity.serviceName,
            p.basenameWithoutExtension(exeName),
          ],
        );
      }
      progress.value = const UpdateProgress(UpdateStage.launching, 0, 0);
      // Windows PowerShell 5.1 没有 BOM 会按 ANSI 读脚本，中文路径 / 文案会乱 → 一律带 UTF-8 BOM
      scriptFile = File(p.join(work.path, 'update.ps1'));
      await scriptFile.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
    } catch (_) {
      await _rmrf(work);
      rethrow;
    }
    Object? launchError;
    try {
      await launch(scriptFile);
    } catch (e) {
      launchError = e;
    }
    final started = launchError == null && await waitForFile(File(p.join(work.path, updaterStartedMarker)), timeout: startTimeout);
    if (!started) {
      // 不清工作目录：包已经校验过，用户可以手动装
      throw UpdateError('更新脚本未能启动${launchError == null ? '' : '：$launchError'}，已下载的更新包保留在 ${work.path}');
    }
    await exitApp();
  }

  static Future<void> _rmrf(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
