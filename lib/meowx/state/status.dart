import 'dart:async';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 图标栏布局（对齐 iPad 的 regular 宽度类）：视口宽 ≥ 700 —— 平板横竖屏、Windows 窗口都走左侧 IconRail。
const railMinWidth = 700.0;

/// 两栏 / 首页宽网格还需要更宽：图标栏 104 + 左栏 360 + 右栏至少 ~430。
const twoPaneMinWidth = 900.0;

final isWideLayoutProvider = Provider<bool>((ref) {
  if (globalState.isAndroidTV) return false;
  return ref.watch(viewWidthProvider) >= railMinWidth;
});

/// 代理 / 连接 / 配置三页的 TwoPane 与首页宽网格。窄于此（平板竖屏）在图标栏右侧用单列。
final isTwoPaneProvider = Provider<bool>((ref) {
  if (globalState.isAndroidTV) return false;
  return ref.watch(viewWidthProvider) >= twoPaneMinWidth;
});

/// 是否已连接（核心运行中）。
final isRunningProvider = Provider<bool>((ref) => ref.watch(runTimeProvider) != null);

/// 取订阅解析后的原始配置；默认问核心，只有测试会换掉。
@visibleForTesting
final rawConfigFetcherProvider = Provider<Future<Map<String, dynamic>> Function(String profileId, String? ageSecretKey)>(
  (ref) => (profileId, ageSecretKey) => clashCore.getConfig(profileId, ageSecretKey: ageSecretKey),
);

/// 取不到订阅配置（核心报错，或请求丢了、60 秒超时回来一张空表）时隔多久再试；这几次都试完才认空表。
@visibleForTesting
List<Duration> rawConfigRetryDelays = const [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 15)];

/// 当前订阅解析后的原始配置（mihomo 自己的解析器），按 profileId 缓存，没人用了（切走的订阅）就释放；
/// 用于：节点安全性副标题（tls / reality / flow / network）、DNS 模式的「跟随订阅」判定。
///
/// 只盯决定文件内容的两个字段：档案文件每次落盘都会更新 lastUpdateDate（`Profile.saveFile` / `saveFileWithString`），
/// 解密用 ageSecretKey。不能订阅整个 Profile——点一次节点（selectedMap）、换一次组（currentGroupName）它都变，
/// 每变一次核心就要重读重解析整份订阅、整份配置的 JSON 再回到 UI isolate 上解码。
///
/// 正因为不再随 Profile 的每次变化重取，取不到时得自己补：
/// - 核心硬重启期间（桌面切订阅就会硬重启）不发请求——它会落在正被关掉的旧 socket 上丢掉。先挂着不出结果
///   （界面沿用上一份），重启标志落下时这里重跑，问新起的核心；重启前已经发出去的那次也由这次重跑顶替。
/// - 核心报错（档案文件还没下回来等）或超时，按 [rawConfigRetryDelays] 重试，不把空表当成结果存下。
final profileRawConfigProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, profileId) async {
  final key = ref.watch(
    profilesProvider.select((s) {
      final p = s.getProfile(profileId);
      return p == null ? null : (p.lastUpdateDate, p.ageSecretKey);
    }),
  );
  if (key == null) return const {};
  if (ref.watch(isRestartingCoreProvider)) return Completer<Map<String, dynamic>>().future;
  // 被顶替（依赖变了重跑）或释放之后就不再重试
  var stale = false;
  ref.onDispose(() => stale = true);
  final fetch = ref.read(rawConfigFetcherProvider);
  for (var attempt = 0; ; attempt++) {
    try {
      final raw = await fetch(profileId, key.$2);
      // 解析成功的配置不会是空表（核心把 RawConfig 的字段全部输出）；空表是请求超时给的默认值
      if (raw.isNotEmpty) return raw;
      commonPrint.log('profileRawConfig($profileId) empty (timeout)');
    } catch (e) {
      commonPrint.log('profileRawConfig($profileId) failed: $e');
    }
    if (stale || attempt >= rawConfigRetryDelays.length) return const {};
    await Future<void>.delayed(rawConfigRetryDelays[attempt]);
    if (stale) return const {};
  }
});

/// 当前订阅的原始配置（未加载 / 无订阅 → 空表）。
final currentRawConfigProvider = Provider<Map<String, dynamic>>((ref) {
  final id = ref.watch(currentProfileIdProvider);
  if (id == null) return const {};
  return ref.watch(profileRawConfigProvider(id)).value ?? const {};
});

/// 节点元信息（来自订阅原始配置的 proxies 列表）。
class ProxyMeta {
  const ProxyMeta({required this.type, this.tls = false, this.reality = false, this.flow = '', this.network = '', this.encryption = ''});
  final String type;
  final bool tls, reality;
  final String flow, network, encryption;

  /// reality|tls → vision → enc → 非 tcp 的 network，`" · "` 连接
  String get securitySubtitle {
    final parts = <String>[];
    if (reality) {
      parts.add('reality');
    } else if (tls) {
      parts.add('tls');
    }
    if (flow.contains('vision')) parts.add('vision');
    if (encryption.isNotEmpty && encryption != 'none' && encryption != 'auto') parts.add(encryption);
    if (network.isNotEmpty && network != 'tcp') parts.add(network);
    return parts.join(' · ');
  }
}

final proxyMetaProvider = Provider<Map<String, ProxyMeta>>((ref) {
  final raw = ref.watch(currentRawConfigProvider);
  final list = raw['proxies'];
  if (list is! List) return const {};
  final out = <String, ProxyMeta>{};
  for (final item in list) {
    if (item is! Map) continue;
    final name = item['name']?.toString();
    if (name == null) continue;
    final realityOpts = item['reality-opts'];
    out[name] = ProxyMeta(
      type: item['type']?.toString() ?? '',
      tls: item['tls'] == true || item['type'] == 'trojan' || item['type'] == 'hysteria2' || item['type'] == 'anytls' || item['type'] == 'miu',
      reality: realityOpts is Map && realityOpts.isNotEmpty,
      flow: item['flow']?.toString() ?? '',
      network: item['network']?.toString() ?? '',
      encryption: item['type'] == 'shadowsocks' ? '' : (item['encryption']?.toString() ?? ''),
    );
  }
  return out;
});

/// 订阅声明的 DNS 增强模式（fake-ip / redir-host / 未声明 → null）。
final declaredDnsModeProvider = Provider<String?>((ref) {
  final raw = ref.watch(currentRawConfigProvider);
  final dns = raw['dns'];
  if (dns is! Map) return null;
  final mode = dns['enhanced-mode']?.toString();
  return (mode == null || mode.isEmpty) ? null : mode;
});
