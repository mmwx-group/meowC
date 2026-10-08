/// MeowX 壳的全部中文文案（与 iOS 端逐字一致；不走 intl 管线）。
class S {
  S._();

  // Tab
  static const home = '首页';

  // 首页
  static const upload = '上传';
  static const download = '下载';
  static const session = '会话';
  static const proxyConnections = '代理连接';
  static const directConnections = '直连连接';
  static const memory = '内存';
  static const coreMemory = '核心内存';
  static const dnsMode = 'DNS 模式';
  static const dnsFakeIp = 'Fake-IP';
  static const dnsRedirHost = 'Redir-Host';
  static const connected = '已连接';
  static const connecting = '连接中';
  static const disconnected = '未连接';
  static const running = '已运行';
  static const ready = '已就绪';
  static const notConfigured = '未配置';
  static const modeRule = '规则';
  static const modeDirect = '直连';
  static const modeGlobal = '全局';
  static const peak = '峰值';
  static const domesticDirect = '国内 · 直连出口';
  static const globalVia = '国际 · 经';
  static const querying = '查询中…';
  static const noSubscription = '还没有订阅';
  static const unlimited = '无限';

  // 代理页
  static String groupsAndNodes(int groups, int nodes) => '$groups 个代理组 · $nodes 个节点';
  static const testAll = '全部测速';
  static const testGroup = '测速本组';
  static const noConfig = '还没有配置';
  static const nodeView = '节点视图';
  static const layout = '布局';
  static const homeCards = '首页卡片';
  static const homeCardsHint = '关掉的卡片不在首页显示；连接主卡始终保留。出口 IP 关掉后也不再查询。';
  static const cardSize = '卡片尺寸';
  static const timeout = '超时';
  static const builtinDirect = '直连';
  static const builtinReject = '拒绝';
  static const builtinPass = '穿透';
  static const builtinGlobal = '全局';
  static const nestedGroup = '代理组';

  // 设置
  static const theme = '主题';
  static const themeSystem = '跟随系统';
  static const themeLight = '亮色';
  static const themeDark = '暗色';
  static const version = '版本';
  static const openSourceLicense = '开源许可';

  // 更新（Windows 一键更新；Android 仍打开下载地址）
  static const checkUpdate = '检查更新';
  static const checkUpdateFailed = '检查更新失败';
  static const checkUpdateFailedHint = '连不上更新服务器，请检查网络后再试。';
  static const downloadApk = '下载 APK';
  static String newVersionAvailable(String tag) => '有新版本 $tag';
  static const updateNow = '立即更新';
  static const updateTitle = '更新 MeowX';
  static const updateDownloading = '正在下载…';
  static const updateExtracting = '正在解压…';
  static const updateLaunching = '正在启动安装，MeowX 将自动重启…';
  static const updateFailed = '更新失败';
  static const goDownloadPage = '去下载页';

  // 通用
  static const tunnelNotConnected = '隧道未连接';
}
