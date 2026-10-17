import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 测速源（与 iOS / macOS 同一组）。Google 只有下载。
enum SpeedTestSource {
  google('Google'),
  apple('Apple'),
  speedtest('Speedtest'),
  cloudflare('Cloudflare');

  const SpeedTestSource(this.title);
  final String title;

  bool get hasUpload => this != SpeedTestSource.google;
}

/// 测速进度 / 结果（核心 meowSpeedTestStatus 回的 JSON，字段同 component/speedtest 的 Progress）。速率单位 Mbps。
@immutable
class SpeedTestProgress {
  const SpeedTestProgress({
    this.runID = 0,
    this.phase = 'idle',
    this.source,
    this.via,
    this.server,
    this.latencyMs,
    this.downloadMbps,
    this.uploadMbps,
    this.downloadPeakMbps,
    this.uploadPeakMbps,
    this.currentMbps = 0,
    this.downloadSamples = const [],
    this.uploadSamples = const [],
    this.phaseProgress = 0,
    this.bytesUsed = 0,
    this.error,
  });

  final int runID;

  /// idle preparing latency download upload done failed cancelled
  final String phase;
  final SpeedTestSource? source;
  final String? via, server, error;
  final int? latencyMs;
  final double? downloadMbps, uploadMbps, downloadPeakMbps, uploadPeakMbps;
  final double currentMbps, phaseProgress;
  final List<double> downloadSamples, uploadSamples;
  final int bytesUsed;

  bool get isRunning => const {'preparing', 'latency', 'download', 'upload'}.contains(phase);

  static double? _d(Object? v) => v is num ? v.toDouble() : null;
  static List<double> _list(Object? v) => v is List ? [for (final e in v) if (e is num) e.toDouble()] : const [];

  factory SpeedTestProgress.fromJson(Map<String, Object?> j) => SpeedTestProgress(
    runID: (j['runID'] as num?)?.toInt() ?? 0,
    phase: j['phase'] as String? ?? 'idle',
    source: SpeedTestSource.values.where((s) => s.name == j['source']).firstOrNull,
    via: j['via'] as String?,
    server: j['server'] as String?,
    latencyMs: (j['latencyMs'] as num?)?.toInt(),
    downloadMbps: _d(j['downloadMbps']),
    uploadMbps: _d(j['uploadMbps']),
    downloadPeakMbps: _d(j['downloadPeakMbps']),
    uploadPeakMbps: _d(j['uploadPeakMbps']),
    currentMbps: _d(j['currentMbps']) ?? 0,
    downloadSamples: _list(j['downloadSamples']),
    uploadSamples: _list(j['uploadSamples']),
    phaseProgress: _d(j['phaseProgress']) ?? 0,
    bytesUsed: (j['bytesUsed'] as num?)?.toInt() ?? 0,
    error: (j['error'] as String?)?.isEmpty == true ? null : j['error'] as String?,
  );

  SpeedTestProgress copyWith({String? phase, double? currentMbps}) => SpeedTestProgress(
    runID: runID,
    phase: phase ?? this.phase,
    source: source,
    via: via,
    server: server,
    latencyMs: latencyMs,
    downloadMbps: downloadMbps,
    uploadMbps: uploadMbps,
    downloadPeakMbps: downloadPeakMbps,
    uploadPeakMbps: uploadPeakMbps,
    currentMbps: currentMbps ?? this.currentMbps,
    downloadSamples: downloadSamples,
    uploadSamples: uploadSamples,
    phaseProgress: phaseProgress,
    bytesUsed: bytesUsed,
    error: error,
  );
}

/// 测速页的状态：测在 Go 核心里跑（meowSpeedTestStart / Status / Stop），这里发开始 / 停止、测的时候每 300ms 拉一次进度。
/// 测速源与单 / 多线程记在本机偏好里。
class SpeedTestController extends ChangeNotifier {
  SpeedTestController({this.call});

  /// 调核心（测试里换成假的）；缺省走 clashCore
  final Future<String?> Function(ActionMethod method, String data)? call;

  static const multiConnections = 8;

  /// 「在浏览器打开网页测速」（与 Bettbox 同一个地址）
  static const webUrl = 'https://ptclspeed.speedtestcustom.com';

  static const _kSource = 'meowx.speedTest.source';
  static const _kMulti = 'meowx.speedTest.multi';

  SpeedTestSource source = SpeedTestSource.google;
  bool multiThread = false;

  /// 测速节点（只能是节点）；null = 首页当前出口实际在用的节点
  String? node;

  SpeedTestProgress progress = const SpeedTestProgress();

  /// 没能开始的原因（未连接、核心太旧…）
  String? message;
  bool _starting = false;
  int _generation = 0;
  bool _loaded = false;

  bool get isRunning => _starting || progress.isRunning;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    source = SpeedTestSource.values.where((s) => s.name == prefs.getString(_kSource)).firstOrNull ?? source;
    multiThread = prefs.getBool(_kMulti) ?? multiThread;
    notifyListeners();
  }

  void setSource(SpeedTestSource value) {
    source = value;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString(_kSource, value.name));
  }

  void setMultiThread(bool value) {
    multiThread = value;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool(_kMulti, value));
  }

  void setNode(String value) {
    node = value;
    notifyListeners();
  }

  Future<String?> _invoke(ActionMethod method, [String data = '']) {
    if (call != null) return call!(method, data);
    return clashCore.clashInterface.invoke<String?>(method: method, data: data, timeout: const Duration(seconds: 10));
  }

  Future<void> start(String via) async {
    if (isRunning) return;
    final generation = ++_generation;
    message = null;
    _starting = true;
    progress = SpeedTestProgress(phase: 'preparing', source: source, via: via);
    notifyListeners();
    String? reason;
    try {
      reason = await _invoke(
        ActionMethod.meowSpeedTestStart,
        json.encode({'source': source.name, 'proxy': via, 'connections': multiThread ? multiConnections : 1}),
      );
    } catch (e) {
      reason = '核心没有响应：$e';
    }
    if (generation != _generation) return;
    // 比 App 旧的核心不认识这个方法：回包是 null
    if (reason == null || reason.isNotEmpty) {
      _starting = false;
      progress = const SpeedTestProgress();
      message = reason ?? '核心版本过旧，重启后再试';
      notifyListeners();
      return;
    }
    _starting = false;
    while (generation == _generation) {
      try {
        final raw = await _invoke(ActionMethod.meowSpeedTestStatus);
        if (generation != _generation) return;
        if (raw != null && raw.isNotEmpty) {
          progress = SpeedTestProgress.fromJson(json.decode(raw) as Map<String, Object?>);
          notifyListeners();
          if (!progress.isRunning) return;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  void stop() {
    _generation++;
    if (!isRunning) return;
    _starting = false;
    progress = progress.copyWith(phase: 'cancelled', currentMbps: 0);
    notifyListeners();
    unawaited(_invoke(ActionMethod.meowSpeedTestStop).catchError((_) => null));
  }
}

/// 全局一份（测速页关掉再打开，上一次的结果还在）。
final speedTestController = SpeedTestController();

/// Mbps 的显示：<10 两位小数，<100 一位，其余取整。
String fmtMbps(double v) => v < 10 ? v.toStringAsFixed(2) : (v < 100 ? v.toStringAsFixed(1) : v.toStringAsFixed(0));
