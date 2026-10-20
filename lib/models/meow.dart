// ignore_for_file: invalid_annotation_target
// （freezed 构造参数上的 @JsonKey 是给生成代码用的，同 lib/models 下其它模型文件）
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

/// 手机端代理页布局：列表 = 可折叠的组卡；单组 = 顶部一个组按钮点开选组，下面只显示这一组的节点。宽屏恒为两栏，不受它影响。
/// 单组以前叫「标签」（横向组标签 + 左右滑动换组），取值仍是 tabs，沿用存下的偏好。
enum ProxyLayout {
  list,
  tabs;

  String get label => switch (this) {
    ProxyLayout.list => '列表',
    ProxyLayout.tabs => '单组',
  };
}

/// 主题风格：经典（实色控件）/ 液态玻璃（浮在内容上面的控件层换成玻璃，内容卡片仍是实色，照 iOS 26 官方 App）。
/// 缺省经典：老用户升级后样子不变。界面与取色在 `lib/meowx/theme/`。
enum MeowThemeStyle {
  classic,
  glass;

  String get label => switch (this) {
    MeowThemeStyle.classic => '经典',
    MeowThemeStyle.glass => '液态玻璃',
  };
}

/// 液态玻璃的样式（照 iOS 26.1 系统设置的同名选项）：透明 = 高透；着色 = 更厚、更不透明、对比度更高。只在液态玻璃下生效。
enum MeowGlassTint {
  clear,
  tinted;

  String get label => switch (this) {
    MeowGlassTint.clear => '透明',
    MeowGlassTint.tinted => '着色',
  };
}

/// 自定义规则的动作：直连 / 代理 / 拒绝。「代理」固定走订阅的主代理组（兜底 MATCH 指向的组，推断见
/// `lib/meowx/state/custom_rules.dart resolveMainProxyGroup`），与 iOS / macOS 同一口径。
enum MeowRuleAction {
  direct,
  proxy,
  reject;

  String get label => switch (this) {
    MeowRuleAction.direct => '直连',
    MeowRuleAction.proxy => '代理',
    MeowRuleAction.reject => '拒绝',
  };
}

/// 自定义规则的匹配方式：域名精确（DOMAIN）/ 后缀含子域名（DOMAIN-SUFFIX）/ 单个 IP（IP-CIDR /32、/128，no-resolve）。
enum MeowRuleMatch {
  domain,
  suffix,
  ip;

  String get label => switch (this) {
    MeowRuleMatch.domain => '仅此域名',
    MeowRuleMatch.suffix => '含子域名',
    MeowRuleMatch.ip => 'IP',
  };
}

/// 用户自己加的分流规则（「我的 › 设置 › 自定义规则」与动态页连接详情里加的）。
/// [value] 是规范化后的域名（小写、不带协议头 / 路径 / 端口）或 IP；列表顺序即优先级（先写的先匹配）。
@freezed
abstract class MeowCustomRule with _$MeowCustomRule {
  const factory MeowCustomRule({
    @Default('') String value,
    @JsonKey(unknownEnumValue: MeowRuleMatch.suffix)
    @Default(MeowRuleMatch.suffix)
    MeowRuleMatch match,
    @JsonKey(unknownEnumValue: MeowRuleAction.direct)
    @Default(MeowRuleAction.direct)
    MeowRuleAction action,
  }) = _MeowCustomRule;

  factory MeowCustomRule.fromJson(Map<String, Object?> json) =>
      _$MeowCustomRuleFromJson(json);
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

/// 用户在客户端里自己添加的 po0 服务器（本机偏好，退出登录不清）。
/// [address] 是规范化后的 `host[:port]`（见 `normalizePo0Address`），[token] 是 trim 后的原文（可带 `@槽位`）。
/// token 在界面 / 日志里一律用 `maskPo0Token` 的脱敏写法。
@freezed
abstract class Po0CustomServer with _$Po0CustomServer {
  const factory Po0CustomServer({
    @Default('') String address,
    @Default('') String token,
  }) = _Po0CustomServer;

  factory Po0CustomServer.fromJson(Map<String, Object?> json) =>
      _$Po0CustomServerFromJson(json);
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

    /// 首页关掉的卡片（HomeCard.name）；网速图默认不显示（Windows 上折线恒在，不受此影响）
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

    /// 自定义规则：经前置规则插在全部订阅规则之前（排在主控直连 / po0 直连之后），只在规则模式生效
    @Default([]) List<MeowCustomRule> customRules,
    @Default(MeowLocalProxy()) MeowLocalProxy localProxy,
    @Default(MeowAccount()) MeowAccount account,

    /// po0 客户端 IP 加白：打开后才拉主控的 po0 列表、连同 [po0Custom] 定时 / 网络变化时上报本机出口 IP
    @Default(false) bool po0Enabled,

    /// 用户自己添加的 po0 服务器：追加在主控下发的之后，没登录也报（仍以 [po0Enabled] 为准）
    @Default([]) List<Po0CustomServer> po0Custom,

    /// 最近一次 po0 服务器（主控的 + 自己添加的）的主机（IP 已规范化、域名小写，去重）：开关打开时据此在规则最前加 DIRECT。
    /// 落盘是为了启动 / 磁贴快速启动（服务 isolate 里没有 Reporter）时规则也在。
    /// 以前只存 IP、键名是 po0DirectIps：沿用这个键，旧数据原样读成主机
    @JsonKey(name: 'po0DirectIps') @Default([]) List<String> po0DirectHosts,

    /// 已做过「TUN 栈 mips → mixed」的一次性回退（之后用户在高级里手选 mips 不会被改回去）
    @Default(false) bool tunStackMipsReverted,

    /// 主题风格（缺省经典）、液态玻璃样式（缺省透明）。存的是枚举名，认不出的值回到缺省
    @JsonKey(unknownEnumValue: MeowThemeStyle.classic)
    @Default(MeowThemeStyle.classic)
    MeowThemeStyle themeStyle,
    @JsonKey(unknownEnumValue: MeowGlassTint.clear)
    @Default(MeowGlassTint.clear)
    MeowGlassTint glassTint,

    /// 内容卡片的颜色（ARGB，缺省白）：两种主题都生效；深色下不直接用，取它的色相压成深色卡（见 `lib/meowx/theme/tokens.dart`）
    @Default(0xFFFFFFFF) int cardColor,

    /// 启动卡片（首页连接主卡）的颜色（ARGB，缺省樱粉 #F7CDDB）：电源键的填充色跟着它的色相走；深色下取色相压成深色
    @Default(0xFFF7CDDB) int heroColor,

    /// 强调色（ARGB，缺省玫红 #B02E63）：强调文字 / 图标、选中态的描边与淡底、底栏选中项、进度条；对比度不够时自动压暗 / 提亮
    @Default(0xFFB02E63) int accentColor,

    /// 已做过「网速图默认隐藏」的一次性迁移（老配置存的是空列表，分不清是没动过还是手动全开；之后用户再打开就保留）
    @Default(false) bool homeChartMigrated,
  }) = _MeowSettings;

  factory MeowSettings.fromJson(Map<String, Object?> json) =>
      _$MeowSettingsFromJson(json);
}
