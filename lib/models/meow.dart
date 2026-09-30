import 'package:freezed_annotation/freezed_annotation.dart';

part 'generated/meow.freezed.dart';
part 'generated/meow.g.dart';

/// DNS 模式：跟随订阅 / 强制 redir-host / 强制 fake-ip（只改 dns.enhanced-mode，生效模式变了才重载）。
enum MeowDnsMode {
  follow,
  @JsonValue('redir-host')
  redirHost,
  @JsonValue('fake-ip')
  fakeIp;

  String get label => switch (this) {
    MeowDnsMode.follow => '跟随订阅',
    MeowDnsMode.redirHost => 'Redir-Host',
    MeowDnsMode.fakeIp => 'Fake-IP',
  };
}

/// 测速方式三档（与 iOS 端设置项一致）。
enum LatencyMode {
  /// HTTPS 延迟（去掉握手的 unified 口径，阈值 100 / 200）
  url,

  /// 真连接延迟（含 TCP + TLS 握手的完整往返，阈值 300 / 600）
  urlFull,

  /// TCPing（只连节点入口端口，阈值 100 / 200）
  tcping;

  String get label => switch (this) {
    LatencyMode.url => 'HTTPS 延迟',
    LatencyMode.urlFull => '真连接延迟',
    LatencyMode.tcping => 'TCPing',
  };

  /// （良好上限, 一般上限）
  (int, int) get thresholds => switch (this) {
    LatencyMode.url => (100, 200),
    LatencyMode.urlFull => (300, 600),
    LatencyMode.tcping => (100, 200),
  };

  /// 传给核心 asyncTestDelay 的 mode 字段
  String get wireName => switch (this) {
    LatencyMode.url => 'url',
    LatencyMode.urlFull => 'url-full',
    LatencyMode.tcping => 'tcping',
  };
}

/// 节点卡片两档：标准 2 列 / 大 1 列（紧凑档已删：3 列时名字挤不下、徽标叠在一起）。
enum NodeCardSize {
  standard,
  large;

  String get label => switch (this) {
    NodeCardSize.standard => '标准',
    NodeCardSize.large => '大',
  };
}

/// 首页上可以关掉的卡片（连接主卡恒在）。隐藏的卡记在 `MeowSettings.homeHiddenCards`（存 name）。
enum HomeCard {
  upload,
  download,
  chart,
  proxied,
  direct,
  memory,
  dns,
  ip;

  String get label => switch (this) {
    HomeCard.upload => '上传',
    HomeCard.download => '下载',
    HomeCard.chart => '网速图',
    HomeCard.proxied => '代理连接',
    HomeCard.direct => '直连连接',
    HomeCard.memory => '内存',
    HomeCard.dns => 'DNS 模式',
    HomeCard.ip => '出口 IP',
  };
}

/// 手机端代理页布局：列表 = 可折叠的组卡；标签 = 顶部横向组标签 + 左右滑动换组。宽屏恒为两栏，不受它影响。
enum ProxyLayout {
  list,
  tabs;

  String get label => switch (this) {
    ProxyLayout.list => '列表',
    ProxyLayout.tabs => '标签',
  };
}

/// 本地代理（HTTP/SOCKS5 混合端口）设置。
@freezed
abstract class MeowLocalProxy with _$MeowLocalProxy {
  const factory MeowLocalProxy({
    @Default(false) bool enabled,
    @Default(7890) int port,
    @Default(false) bool allowLan,
    @Default('') String username,
    @Default('') String password,
  }) = _MeowLocalProxy;

  factory MeowLocalProxy.fromJson(Map<String, Object?> json) =>
      _$MeowLocalProxyFromJson(json);
}

/// 妙妙屋X 主控账户。
@freezed
abstract class MeowAccount with _$MeowAccount {
  const factory MeowAccount({
    @Default('') String host,
    @Default('') String token,
    @Default('') String nickname,
    @Default('') String avatarUrl,
  }) = _MeowAccount;

  factory MeowAccount.fromJson(Map<String, Object?> json) =>
      _$MeowAccountFromJson(json);
}

/// MeowX 壳自己的设置（挂在 Config.meow 上，随 Bettbox 的偏好一起落盘）。
@freezed
abstract class MeowSettings with _$MeowSettings {
  const factory MeowSettings({
    @Default(MeowDnsMode.follow) MeowDnsMode dnsMode,
    @Default(LatencyMode.url) LatencyMode latencyMode,
    @JsonKey(unknownEnumValue: NodeCardSize.standard)
    @Default(NodeCardSize.standard)
    NodeCardSize nodeCardSize,
    @JsonKey(unknownEnumValue: ProxyLayout.list)
    @Default(ProxyLayout.list)
    ProxyLayout proxyLayout,

    /// 当前的 mode=direct 是切到内置直连档时自动设的（不是用户手选）：离开直连档时据此恢复 rule
    @Default(false) bool autoDirectMode,

    /// 首页关掉的卡片（HomeCard.name）；网速图默认不显示（Windows 上该位置是接管卡，不受此影响）
    @Default(['chart']) List<String> homeHiddenCards,

    /// 订阅同步间隔（小时），0 = 手动
    @Default(24) int syncIntervalHours,

    /// 推送服务直连（关闭「代理推送服务」= true：FCM / GMS / APNs 走 DIRECT）
    @Default(false) bool pushDirect,

    /// DNS 劫持：域名 → IPv4
    @Default({}) Map<String, String> dnsHijack,

    /// 绕过代理：域名与 CIDR
    @Default([]) List<String> bypassDomains,
    @Default([]) List<String> bypassCidrs,
    @Default(MeowLocalProxy()) MeowLocalProxy localProxy,
    @Default(MeowAccount()) MeowAccount account,

    /// 已做过「TUN 栈 mips → mixed」的一次性回退（之后用户在高级里手选 mips 不会被改回去）
    @Default(false) bool tunStackMipsReverted,

    /// 已做过「网速图默认隐藏」的一次性迁移（老配置存的是空列表，分不清是没动过还是手动全开；之后用户再打开就保留）
    @Default(false) bool homeChartMigrated,
  }) = _MeowSettings;

  factory MeowSettings.fromJson(Map<String, Object?> json) =>
      _$MeowSettingsFromJson(json);
}
