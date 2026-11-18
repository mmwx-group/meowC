import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 订阅里远程的 proxy-provider（http 节点集）；没有就是空。节点视图菜单据此决定给不给「更新节点集」（同 iOS）。
final remoteProxyProvidersProvider = Provider<List<String>>((ref) {
  final all = ref.watch(providersProvider);
  return [
    for (final p in all)
      if (p.type == 'Proxy' && p.vehicleType.toUpperCase() == 'HTTP') p.name,
  ];
});

/// 正在更新节点集。
final updatingProxyProvidersProvider = StateProvider<bool>((ref) => false);

/// 重新拉取全部远程节点集；返回失败的那几条（「名字: 原因」），全部成功是空。
Future<List<String>> updateProxyProviders(WidgetRef ref) async {
  final busy = ref.read(updatingProxyProvidersProvider.notifier);
  if (busy.state) return const [];
  final names = ref.read(remoteProxyProvidersProvider);
  if (names.isEmpty) return const [];
  busy.state = true;
  final failed = <String>[];
  try {
    final notifier = ref.read(providersProvider.notifier);
    await Future.wait(names.map((name) async {
      final message = await clashCore.updateExternalProvider(providerName: name);
      if (message.isNotEmpty) failed.add('$name: $message');
      notifier.setProvider(await clashCore.getExternalProvider(name));
    }));
    globalState.appController.updateGroupsDebounce();
  } finally {
    busy.state = false;
  }
  return failed;
}
