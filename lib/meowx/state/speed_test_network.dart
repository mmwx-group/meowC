import 'package:bett_box/common/system.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:wifi_ssid/wifi_ssid.dart';

// 测速记录里的「网络」：点开始那一刻本机的物理网络（与 iOS / macOS 同一组文字）——
// Wi-Fi、5G、4G、3G、2G、移动数据（是蜂窝但分不出代）、有线网络；取不到的不记、不显示。

/// 安卓蜂窝制式码（TelephonyManager.NETWORK_TYPE_*，NetworkInfo.getSubtype）→ 代；未知、IWLAN（Wi-Fi 通话）这类分不出的 null。
/// 5G NSA 系统报的是 LTE，显示 4G。
String? cellularGeneration(int? subtype) => switch (subtype) {
  20 => '5G', // NR
  13 || 19 => '4G', // LTE、LTE_CA
  // UMTS、EVDO_0 / A / B、HSDPA、HSUPA、HSPA、EHRPD、HSPAP、TD_SCDMA
  3 || 5 || 6 || 8 || 9 || 10 || 12 || 14 || 15 || 17 => '3G',
  1 || 2 || 4 || 7 || 11 || 16 => '2G', // GPRS、EDGE、CDMA、1xRTT、IDEN、GSM
  _ => null,
};

/// connectivity_plus 的结果里挑本机物理网络：开着 VPN 时安卓回 [vpn, wifi] 这类（VPN 网络带着底层网络的类型），VPN 不算。
/// 同时有几种时 Wi-Fi > 有线 > 蜂窝（Windows 上 Hyper-V / WSL 的虚拟网卡也报成有线，Wi-Fi 在前才不会把无线笔记本记成有线）。
ConnectivityResult? physicalNetworkOf(List<ConnectivityResult> results) => const [
  ConnectivityResult.wifi,
  ConnectivityResult.ethernet,
  ConnectivityResult.mobile,
].where(results.contains).firstOrNull;

/// 显示文字：蜂窝按 [cellularSubtype] 分代，分不出写「移动数据」；不是这三种 null
String? speedTestNetworkLabel(ConnectivityResult? network, {int? cellularSubtype}) => switch (network) {
  ConnectivityResult.wifi => 'Wi-Fi',
  ConnectivityResult.ethernet => '有线网络',
  ConnectivityResult.mobile => cellularGeneration(cellularSubtype) ?? '移动数据',
  _ => null,
};

/// 现在的本机网络。蜂窝的制式只有安卓取得到（wifi_ssid 插件的 getNetworkState，不要额外权限）；Windows 只分 Wi-Fi / 有线。
/// 出任何错都当取不到。
Future<String?> currentSpeedTestNetwork() async {
  try {
    final network = physicalNetworkOf(await Connectivity().checkConnectivity());
    int? subtype;
    if (network == ConnectivityResult.mobile && system.isAndroid) {
      try {
        subtype = (await wifiSsidManager.getNetworkState()).cellularSubtype;
      } catch (_) {}
    }
    return speedTestNetworkLabel(network, cellularSubtype: subtype);
  } catch (_) {
    return null;
  }
}
