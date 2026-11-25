import 'package:bett_box/state.dart';

import '../config/mesh_whitelist.dart';
import 'subscription_meta_store.dart';

/// 这份订阅档是不是登录的主控的（[isOwnPanelSubscription]；上次拉它时主控给的实时通道地址从订阅元数据里取）。
bool isOwnPanelProfile(String profileId, String url, String panelBase) =>
    isOwnPanelSubscription(url, panelBase, realtimeBase: subscriptionMetaStore.metas.value[profileId]?.realtimeBase);

/// 拉订阅（`Profile.update`，Bettbox 层）时的请求头：本主控的订阅加上 `X-MeowX-Mesh: on|off`（规格 B2），其余原样。
/// 在 globalState 里跑（拿不到 Riverpod），设置从 `globalState.config.meow` 取。
Map<String, String>? meowSubscriptionRequestHeaders(String profileId, String url, Map<String, String>? headers) {
  try {
    final meow = globalState.config.meow;
    // 主控地址退出登录后也留着：登录过期 / 退出后拉本主控的订阅照样带（off）
    final own = isOwnPanelProfile(profileId, url, meow.account.host);
    return withMeshSubscriptionHeader(headers, own: own, on: meshWhitelistOn(meow));
  } catch (_) {
    return headers;
  }
}
