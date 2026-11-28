// 改文案时 arb（intl_zh_CN / intl_zh_TC / intl_en，跑 `dart run intl_utils:generate`）与这里的简体回落一起改。
import 'package:bett_box/l10n/l10n.dart';
import 'package:flutter/widgets.dart';

/// 喵窝设备中继（路径 / 设备详情 / 中继设置）的文案：走 arb（zh_CN / zh_TC / en，别的语言回落英文），
/// 多语言没加载时（单测）用简体。
class MeshRelayText {
  MeshRelayText.of(BuildContext context) : _l = AppLocalizations.maybeOf(context);
  const MeshRelayText.zh() : _l = null;

  final AppLocalizations? _l;

  String get pathDirect => _l?.meshPathDirect ?? '直连';
  String pathViaRelay(String name) => _l?.meshPathViaRelay(name) ?? '经 $name 中继';
  String pathViaRelayOther(String name) => _l?.meshPathViaRelayOther(name) ?? '经 $name 中继（他人的）';
  String pathViaRelayAddr(String addr) => _l?.meshPathViaRelayAddr(addr) ?? '经设备中继 $addr';
  String get pathViaDeviceRelay => _l?.meshPathViaDeviceRelay ?? '经设备中继';
  String pathViaDerp(String name) => _l?.meshPathViaDerp(name) ?? '经中继服务器 $name';
  String get pathViaDerpPlain => _l?.meshPathViaDerpPlain ?? '经中继服务器';
  String get pathIdle => _l?.meshPathIdle ?? '空闲';
  String minutesAgo(String n) => _l?.meshMinutesAgo(n) ?? '$n 分钟前';
  String get justNow => _l?.meshJustNow ?? '刚刚';
  String get deviceDetails => _l?.meshDeviceDetails ?? '设备详情';
  String get deviceAddress => _l?.meshDeviceAddress ?? '地址';
  String get devicePath => _l?.meshDevicePath ?? '路径';
  String get devicePeerView => _l?.meshDevicePeerView ?? '主控记录';
  String get devicePeerViewNote => _l?.meshDevicePeerViewNote ?? '主控汇总的两端上报（对端视角）';
  String get reportedByBoth => _l?.meshReportedByBoth ?? '两端都报了';
  String reportedByOne(String name) => _l?.meshReportedByOne(name) ?? '$name 报的';
  String get deviceTraffic => _l?.meshDeviceTraffic ?? '流量';
  String get deviceLastHandshake => _l?.meshDeviceLastHandshake ?? '最近握手';
  String get none => _l?.meshNone ?? '还没有';
  String get noRecord => _l?.meshNoRecord ?? '没有记录';
  String get copyAddress => _l?.meshCopyAddress ?? '复制地址';
  String get offline => _l?.meshOffline ?? '离线';
  String get notInEngine => _l?.meshNotInEngine ?? '本机暂时没有到它的连接';
  String get relayTag => _l?.meshRelayTag ?? '中继';
  String get relaySettings => _l?.meshRelaySettings ?? '中继设置';
  String get relaySettingsNote => _l?.meshRelaySettingsNote ?? '打不通直连的设备可以经它转发，比中继服务器快';
  String get relaySwitch => _l?.meshRelaySwitch ?? '作为喵窝中继';
  String get relayPort => _l?.meshRelayPort ?? 'UDP 端口';
  String get relayPortNote => _l?.meshRelayPortNote ?? '1024–65535，缺省 40000';
  String get relayEndpoints => _l?.meshRelayEndpoints ?? '静态地址';
  String get relayEndpointsNote => _l?.meshRelayEndpointsNote ?? '做了端口映射、或探测不到公网地址时填写，写成公网 IP:端口（IPv6 加方括号），最多 4 个';
  String get relayAddEndpoint => _l?.meshRelayAddEndpoint ?? '添加地址';
  String get relayDdns => _l?.meshRelayDdns ?? 'DDNS 域名';
  String get relayDdnsNote => _l?.meshRelayDdnsNote ?? '家里 IP 会变时填写，中继设备每 5 分钟解析一次';
  String get relayShare => _l?.meshRelayShare ?? '共享范围';
  String get relayShareSelf => _l?.meshRelayShareSelf ?? '仅本账号';
  String get relayShareAll => _l?.meshRelayShareAll ?? '所有成员';
  String get relayStatus => _l?.meshRelayStatus ?? '状态';
  String get relayStateDisabled => _l?.meshRelayStateDisabled ?? '未开启';
  String get relayStatePending => _l?.meshRelayStatePending ?? '等待设备响应';
  String get relayStateActive => _l?.meshRelayStateActive ?? '正在工作';
  String get relayStateVersionTooOld => _l?.meshRelayStateVersionTooOld ?? 'tailscale 版本过低';
  String get relayStateError => _l?.meshRelayStateError ?? '出错';
  String get relayStateOffline => _l?.meshRelayStateOffline ?? '设备离线';
  String get relayPendingStuck => _l?.meshRelayPendingStuck ?? '设备未响应，确认已安装新版 MeowX 并在线';
  String relayPortForward(String port) => _l?.meshRelayPortForward(port) ?? '设备在路由器后面时，要在上级路由器上把 UDP $port 映射到这台设备';
  String relayVersion(String v) => _l?.meshRelayVersion(v) ?? 'tailscale $v';
  String get save => _l?.meshRelaySave ?? '保存';
  String get saved => _l?.meshRelaySaved ?? '已保存';
  String get relaySessions => _l?.meshRelaySessions ?? '正在经它中继';
  String get relayNoSessions => _l?.meshRelayNoSessions ?? '现在没有经它中继的连接';
  String relayUnmatched(String n) => _l?.meshRelayUnmatched(n) ?? '另有 $n 个未识别的连接';
  String get otherUser => _l?.meshOtherUser ?? '其他用户';
  String get relayNotCapable => _l?.meshRelayNotCapable ?? '这台设备没有上报过中继能力（要 OpenWrt / 飞牛 / Docker 上的新版 MeowX），开不了中继';
  String get errInvalidRequest => _l?.meshRelayErrInvalidRequest ?? '请求无效';
  String get errInvalidPort => _l?.meshRelayErrInvalidPort ?? '端口要在 1024–65535 之间';
  String get errInvalidEndpoint => _l?.meshRelayErrInvalidEndpoint ?? '静态地址要写成公网 IP:端口（IPv6 加方括号），不能是私网或喵窝地址，最多 4 个';
  String get errInvalidDdns => _l?.meshRelayErrInvalidDdns ?? 'DDNS 域名格式不对';
  String get errShareNotAllowed => _l?.meshRelayErrShareNotAllowed ?? '只有管理员能共享给所有成员，已改回仅本账号';
  String get errDeviceNotFound => _l?.meshRelayErrDeviceNotFound ?? '设备不存在或已删除，已刷新设备列表';
  String get errDisabled => _l?.meshRelayErrDisabled ?? '管理员关闭了设备中继';
  String get errRateLimited => _l?.meshRelayErrRateLimited ?? '操作太频繁，稍后再试';
}
