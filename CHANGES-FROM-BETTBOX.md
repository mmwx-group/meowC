# 相对 Bettbox 的修改记录

按 GPL-3.0 §5(a) 要求，列出对 Bettbox（v1.19.2, b2d8734）的修改。日期为落地日期。

## 2026-09-20 · 品牌与工程初始化
- 应用名 Bettbox → MeowX；Android `applicationId` → `com.miaomiaowux.app`（Kotlin 包名与 JNI 符号未改）；深链 scheme `bettbox://` → `miaomiaowu://login`，保留 `clash://` / `clashmeta://`。
- Windows：可执行文件 / 核心 / helper 服务 / 命名管道 / 数据目录改名为 MeowX 系；Inno Setup `app_id` 换新 GUID（不与 Bettbox 互相覆盖）；移除随包分发的第三方二进制 `WindowsLoopbackManager.exe`（来源不明），对应设置项仅在用户自行放置该文件时出现。
- 窗口最小尺寸 380×400 → 900×600（MeowX 平板式三栏布局）。
- 订阅拉取 UA 与 mihomo `global-ua` 改为 `mihomo/1.19.0 (miaomiaowu; <OS>)`，与 MeowX iOS 端一致。
- 默认测速地址改为 `https://cp.cloudflare.com/generate_204`。
- 自更新检查指向 `mmwx-group/meowC`，下载直链前缀 `MeowX-`。
- CI：新增 `ci.yaml`（analyze + test）；`build.yaml` 只保留 Android（arm64 / universal）与 Windows（amd64），移除 Linux / macOS 与 SignPath 签名步骤，增加 `workflow_dispatch` 手动构建。
- 版本号从 0.1.0 重新计数。

## 2026-09-20 · MeowX 壳（P1 第一轮）
- `lib/main.dart`：`runApp` 前 `LiquidGlassWidgets.initialize()` 预热液态玻璃 shader，App 外层包 `LiquidGlassWidgets.wrap`（让玻璃跟随 App 的深浅色）；手机底栏换成 `liquid_glass_widgets` 的 `GlassTabBar.bottom`（Impeller 上真折射，Skia 上自动降级为模糊 + 高光）。
- `lib/application.dart`：`home` 由 Bettbox `HomePage` 换成 `lib/meowx/app/meow_root.dart` 的 `MeowRoot`（手机底部 4 Tab 的液态玻璃底栏 / 宽屏左侧栏 `MeowSidebar`），主题改为 `meowThemeData`（奶白 / 樱粉 / 墨色的 MM token，不再动态取色）。Bettbox 原页面经「我的 → 高级」`ToolsView` 原样进入；Bettbox 内部 `toPage(PageLabel)` 经 `currentPageLabelProvider` 映射到 Tab 或 push。
- `lib/models/config.dart`：`Config` 增加 `meow: MeowSettings`（`lib/models/meow.dart`，MeowX 自己的设置：DNS 模式 / 测速方式 / 节点卡片档位 / 同步间隔 / 覆写 / 本地代理 / 账户）；`openLogs` 默认 `false`，`safeFromJson` 不再强制打开日志流。
- `lib/providers/state.dart`：`configState` 纳入 `meow`，随 Bettbox 偏好一起落盘。
- 新增 `lib/meowx/`：主题 token / GlassCard / TypeBadge / PageTitle / TwoPane 与共用元件（`theme/widgets.dart`：线性图标、分段、电源键、地区码标签）；壳（`app/`：四个 Tab、侧栏）；首页 / 节点 / 动态 / 我的四页及二级页；共用状态 `state/connection.dart`（电源键、当前节点、连接计数轮询、Windows 接管方式）。

## 2026-09-20 · 面板集成与 P2 页面
- `core/hub.go`：测速三档（`TestDelayParams.mode`：url / url-full / tcping），桥层自己做 unified 口径与 TCPing，不翻 mihomo 全局 `unified-delay`；`lib/clash/{interface,core}.dart` 透传 `mode`；`lib/views/proxies/common.dart` 按 MeowX 设置传 mode。
- `lib/state.dart patchRawConfig`：接入 MeowX 的 DNS 模式（`applyMeowDns`）、DNS 劫持 → hosts、本地代理凭据 → authentication、绕过代理 / 推送直连规则前置。
- `lib/models/profile.dart Profile.update()`：多解析 `profile-title`（可 `base64:`）作档案名、`profile-update-interval` 作自动更新间隔。
- `lib/common/link.dart` / `lib/controller.dart initLink`：`miaomiaowu://login?host=&code=` 深链登录。
- `pubspec.yaml`：新增 `cryptography`（Apache-2.0）、`web_socket_channel`。
- 新增 `lib/meowx/panel/`：主控证书验签、加密 RPC、WS 会话（对拍向量 `test/meowx/fixtures/vectors.json` 由 CryptoKit 从规格生成）、账户动作、实时通道；`lib/meowx/pages/` 配置页 / 连接页 / 设置页全部分组与子页（DNS 劫持、绕过代理）。

## 2026-09-21 · 模拟器实测后的修正
- `lib/pages/scan.dart`：未授权时先申请相机权限（原逻辑只检查不申请，首次必落到「权限被拒」页）；识别结果不再限定 URL 类型（MeowX 登录码是 `miaomiaowu://` 自定义 scheme，ML Kit 判成 text）；相册选图的结果同样交回打开扫码页的调用方。
- `lib/common/picker.dart`：新增 `pickerQRCodeRaw()`（相册取码不做 URL 校验）。
- `lib/models/profile.dart`：档案名回落顺序 title → content-disposition → URL 主机名 → 「订阅」。
- `.github/workflows/build.yaml`：手动构建按 stable 出包（不带 PRE 角标）。

## 2026-09-21 · Windows 便携版
- `lib/common/path.dart`：程序目录存在 `portable` 标记文件时，数据目录改为程序目录下的 `data/`。
- `build.yaml`：Windows job 额外产出 `MeowX-<ver>-windows-amd64-portable.zip`。

## 2026-09-21 · 宽屏布局
- `lib/manager/app_manager.dart`：关掉 Bettbox 桌面侧栏（MeowX 壳自带侧栏）；去掉右上角的 DEBUG / PRE 斜角标。
- `lib/manager/window_manager.dart`：窗口标题栏底色并进页面底（不再是一条色带）；`lib/models/config.dart`：新装默认窗口 1100×720（放得下完整侧栏）。
- `lib/common/tray.dart`：托盘菜单按设计稿重排（显示 / 启停 → 模式 → TUN / 系统代理 → 代理组 → 开机启动 / 终端代理命令 / 重启内核 → 更多 → 退出）。
- `lib/common/request.dart`、`lib/controller.dart`：手动检查更新区分「已是最新」与「检查失败」（`manualCheckUpdate`）；新版本弹窗写明当前版本与安装包（文件名 · 大小）。Android 匹配到安装包时按钮为「立即更新」：App 内下载到 cacheDir/meowx-update/、按清单 size + sha256 校验后交给系统安装器（`lib/meowx/update/android_updater.dart`；以前只打开下载地址，用户下到半截的包小米安装器报「packageInfo is null」）。底层配套：`AndroidManifest.xml` 加 `REQUEST_INSTALL_PACKAGES` 与 `androidx.core.content.FileProvider`（`${applicationId}.update`，`res/xml/update_paths.xml`），`AppPlugin.kt` 加 `installApk`（Android 8+ 没允许「安装未知应用」时打开设置页、返回 permission），`lib/plugins/app.dart` 加对应调用。
- 首页（仅 Windows）：网速图位置换成「接管方式」卡（TUN / 系统代理，开关沿用 Bettbox 的 provider）。

## 2026-09-27 · 悬空规则引用不再废掉整份配置
- 新增 `core/meow_rules.go`（+ `core/meow_rules_test.go`）：`meowSanitizeDanglingRules` 在 `UnmarshalRawConfig` 之后、`ParseRawConfig` 之前，把引用了配置里不存在的出站的规则改成 `PASS`、引用了不存在 rule-provider 的规则删掉（子规则同理），并写 warn 日志。
- `core/hub.go handleValidateConfig`：由 `config.Parse` 改为 `UnmarshalRawConfig` → 消毒 → `ParseRawConfig`，让导入校验与实际应用同一套宽容度。
- `core/common.go setupConfig`：`ParseRawConfig` 前同样消毒。

## 2026-09-29 · TUN 栈默认改回 mixed
- `lib/models/clash_config.dart`：`Tun.stack` 默认恢复 Bettbox 原值 `mixed`（09-22 曾改为 mihomo 的 `mips` 用户态栈；Android 分应用白名单下 Google Play / OKX 不通，同配置 mixed 正常）。
- `lib/models/config.dart compatibleFromJson`：一次性把存着 `mips` 的配置改回 `mixed`，迁完记 `meow.tunStackMipsReverted`，之后在「高级」里手选 `mips` 仍保留；去掉 09-22 的 `mixed → mips` 迁移及其标记 `tunStackMigrated`。

## 2026-09-29 · Windows 多屏窗口位置
- `lib/common/window.dart`：还原窗口位置改为按屏换算——存盘坐标（`getBounds`，按保存时所在屏缩放）、屏幕工作区（`screen_retriever`，按各屏自己的缩放）、`setPosition`（按当前所在屏缩放）三者口径不同，多屏且缩放不一致时原逻辑会把窗口放到屏外 / 别的屏；换算逻辑在 `lib/meowx/state/window_placement.dart`。标题栏放不进任何一块屏时居中，超出右 / 下边的部分收回屏内；居中前先定尺寸（原来按默认 1280×720 居中会偏右下）。
- `lib/common/window.dart show()`：从托盘显示前同样检查，藏在托盘期间拔了显示器时挪回主屏居中。

## 2026-09-30 · po0 客户端 IP 加白
- 新增 `core/meow_po0.go`：`meowPo0Report` action——用 mihomo 直连 dialer（与 DIRECT 出站同一条路，Android 经 socket protect 出 VPN、Windows TUN 经 sing-tun 绑物理网卡）向 po0 服务器 POST 空 body、跳过证书校验、10s 超时，逐 url 返回状态码与响应体；`core/constant.go` / `core/action.go` 登记该方法。上报失败的告警日志里 url 与错误（Go 的 url.Error 带整个 url）中的 token 脱敏（`meowPo0Redact`，2026-10-14 加，测试 `core/meow_po0_test.go`）。
- `lib/enum/enum.dart`（`ActionMethod.meowPo0Report`）与生成文件 `lib/models/generated/core.g.dart`（枚举映射手动补一行，与 build_runner 输出一致）。
- 上报调度在 `lib/meowx/state/po0_reporter.dart`（登录 / 启动后、`refreshExtras`、网络变化（`connectivity_plus`）、每 10 分钟），列表模型与地址 / token 的校验、规范化、脱敏、合并在 `lib/meowx/panel/po0.dart`。
- `lib/models/meow.dart MeowSettings`：`po0Enabled`（默认 false）、`po0Custom`（2026-10-14 加：用户自己添加的 po0 服务器 `Po0CustomServer{address, token}`，本机偏好、退出登录不清；设置页「po0 加白」开关下面一行「自定义 po0 服务器」进子页 `lib/meowx/pages/settings/po0_servers_page.dart` 增删，token 只显示脱敏写法）与 `po0DirectHosts`（最近一次上报目标——主控下发的 + 自己添加的，按上报地址去重——的主机缓存，IP 或域名；JSON 键沿用旧名 `po0DirectIps`，旧数据原样兼容。开关打开时经 `meowPrependRules` 在规则最前加 `IP-CIDR(6),<ip>,DIRECT,no-resolve` / 域名 `DOMAIN,<host>,DIRECT`，列表或自定义条目变化时与其它覆写同样 `applyProfileDebounce` 热生效）。所有上报入口（启动 / 登录 / refreshExtras / 定时 / 网络变化 / 增删自定义条目）以开关为准；没登录时只报自己添加的。

## 2026-10-08 · 界面性能（动到 Bettbox 底层的部分）
- `lib/clash/interface.dart`：新增 `handleMessage`（Android 的 ReceivePort 与 Windows 的 socket 两处监听的统一入口，`lib/clash/lib.dart` / `lib/clash/service.dart` 改为调它）——① 没有界面在看时 `request` 推送不解码（见下）；② `getProxies` 的回包不在 UI isolate 解，原始字符串整包交给调用方（`_completeRawProxies`）；③ 其余超过 32KB 的回包（连接快照、整份配置）放到后台 isolate 解信封，小消息照旧同步解。`handleResult` 取 completer 时即从 `callbackCompleterMap` 移除（原来只 complete 不移除，要等 30s 后的清理定时器，回包被多留 30 秒）。
- `lib/clash/message.dart`：核心每关一条连接推一条的 `request` 消息，没有界面在看时只留原文（最近 256 条，与请求列表容量一致）、不逐条解码入库；`lib/views/connection/requests.dart`（旧「请求」页）打开时补解并恢复逐条处理，`lib/controller.dart` 换配置清空请求列表时一并清掉。
- `lib/clash/core.dart`：`getProxies` 的解码、合并 provider、建 `Group` 都在 worker isolate 里做（原始回包字符串直接交过去），同时算出内容摘要；`lib/controller.dart` 的 `updateGroups` 摘要没变就不写 `groupsProvider`。`lib/manager/app_manager.dart` / `clash_manager.dart`：Android 界面不可见时不刷新代理组、回前台补一趟；界面发起的测速进行中不为每条结果再排一趟刷新；`lib/views/proxies/common.dart` 测速收尾的那一趟照旧。
- `lib/providers/state.dart`：`getSelectedProxyNameProvider` 只取 `(type, now)`，不再把整个 `Group` 选出来逐成员深比较。
- 启动：`lib/clash/lib.dart` 的 `_waitForIpc` 超时后不再换掉还没完成的 completer（慢机器上会永远停在启动页的死等）；`lib/main.dart` 等核心通道就绪加了 2 秒上限，内置面板解压（`uiManager.initializeUI`）挪到 `AppController._initCore` 里核心初始化之前，code_forge 的 Rust 库改为按需加载（`lib/pages/editor.dart` 的 `ensureEditorRuntime`，各编辑入口先等它）。
- Windows：`lib/controller.dart` 的 `init()` 让主窗口在首帧后就显示（不再等核心拉起、配置应用完），静默启动 / 托盘启动的分支照旧；启动时代理组不再连拉 2–3 次。`lib/common/tray.dart` / `lib/manager/tray_manager.dart`：托盘菜单改成右键弹出前才重建，状态变化时不再整份重建原生菜单。**这两处没有在 Windows 上实跑过。**
- `lib/common/preferences.dart`：桌面端 autoLaunch 没变就不重写，每次存盘少一遍同步整文件写。
- `lib/main.dart`：液态玻璃底栏挂了库的自适应档位（`GlassAdaptiveScope`），目前只采数据、不降档（minQuality 仍是 premium），默认观感不变。
- `lib/application.dart`：亮 / 暗两份主题走缓存（`MeowThemes`）；`lib/views/about.dart`：关于页图标用 256 的小图。
- 连接快照的取用在 `lib/meowx/state/connection.dart`（`ConnStatsController`）：没有界面显示连接数时不拉，可见页面取到的完整快照顺手更新计数。

## 2026-10-09 · 内核：Miu 换成第二版
- `core/Clash.Meta/transport/miu/`、`core/Clash.Meta/adapter/outbound/miu.go`：自有协议 Miu 整体换成第二版（通道池 + 原样转发：一条通道一条流，流结束后回池复用；内层已是 TLS 1.3 密文的数据不再套外层加密；中止发 RESET、不废通道；UDP 走流里的 UoT）。与第一版线上格式不兼容，服务端同步换成第二版；第一版代码在标签 `miu-v1`。节点配置不变（`type: miu` + `psk`），第一版的 `vision` / `recv-window` 字段忽略。
- 测试：`transport/miu/miu_test.go`（离线）；`live_test.go` 对参考服务端（`MIU_LIVE_MIUX=<miux 二进制>`：TLS / uTLS / REALITY、UDP、通道池、中止、重放）。

## 2026-10-09 · 内核：AnyTLS 支持 REALITY
- `core/Clash.Meta/adapter/outbound/anytls.go`：AnyTLS 出站认 `reality-opts`（`public-key` / `short-id`，与 trojan / vless 同一套写法，必须带 `client-fingerprint`），与 ShadowTLS / Restls / JLS 互斥。上游 mihomo 的 AnyTLS 没有 REALITY：主控下发的 anytls + REALITY 节点此前在这里被当成普通 TLS 握手、连不上。握手本身沿用 `vmess.StreamTLSConn` 里已有的 REALITY 分支，没有新代码路径。
- 测试 `core/Clash.Meta/adapter/outbound/anytls_reality_test.go`：配置解析 / 互斥；对真实服务端的用例要 `ANYTLS_REALITY_LIVE=host:port` 加 `ANYTLS_REALITY_PASSWORD` / `_PBK` / `_SID` / `_SNI`。

## 2026-10-09 · 订阅请求带官方客户端标记
- `lib/common/package.dart`：默认 UA 由 `mihomo/1.19.0 (miaomiaowu; <系统>)` 改为 `mihomo/1.19.0 MeowX/<版本> (<系统>)`（开头的 mihomo/1.19.0 不动：主控与第三方机场靠它给完整 clash YAML；品牌名用 MeowX，不再出现 miaomiaowu）。主控认出这个标记就下发只有官方内核才支持的节点（AnyTLS + REALITY）。用户在「常规」里自定义了全局 UA 时仍以用户填的为准。

## 2026-10-13 · 奖牌 / 解锁按 type·server·port 认节点
- `lib/state.dart patchRawConfig`：应用当前订阅的配置时调 `captureNodeKeys(rawConfig)`（`lib/meowx/panel/node_match.dart`），记下各节点的 type / server / port。主控的套餐订阅会给节点改名（套餐内名称、倍率前缀、流量 / 到期尾缀、重名序号），奖牌与解锁原来只按节点名匹配、改过名就不显示；现在名字对不上时按这组键认（主控回包里同步多带这三项）。其余改动都在 `lib/meowx/`。

## 2026-10-13 · 内核：Snell 支持 v6
- `core/Clash.Meta/transport/snell/`：新增 Snell v6 客户端——`v6.go`（三种模式、请求 / 应答、不复用的 TCP 连接、UDP 隧道）、`v6_record.go`（三种模式的 record 读写）、`v6_profile.go`（默认模式的整形参数：全部由 PSK 派生，前缀 / padding 长度、填充字节生成器、salt 块、padding 与密文混排）、`v6_reuse.go`（连接复用池）。按 sagernet/sing-snell 的 `snellv6`（GPL-3.0）移植，各文件头保留出处，没有引入新依赖。`snell.go` 只加了 `Version6` 常量，`PacketConn` 遇到 v6 隧道原样返回；v1–v5 的代码路径没动。
- `core/Clash.Meta/adapter/outbound/snell.go`：`version: 6` 走新客户端。新增节点字段 `mode`：`default`（整形，不写即此）/ `unshaped`（只加密不整形）/ `unsafe-raw`（明文分帧），须与服务端一致，写错报配置错误；v6 没有 obfs 这一层，带了 `obfs-opts` 一律忽略（参考实现是报配置错误；这里不让一个写错的节点否掉整份配置，与 iOS / macOS 端一致）；`udp: true`、`reuse: true` 可用。v1–v5 照旧不看 `mode`。出站 `Close()` 时关掉 v6 连接池。
- 复用：一条连接同一时间只跑一个请求，双方各发一个空 record 结束自己这一半之后才给下一个请求用；客户端先关的，由还挂着的读或后台排空等到服务端的空 record 再回池（期间最多丢弃 0x80001 字节）。与参考实现有两处不同：① 只有真的收到服务端的空 record 才复用——参考实现把「服务端直接关掉 TCP」也算正常结束，连接会被放回池里、下一个请求必然失败，而我们的 Xray 服务端正是每个请求结束就关连接（所以对它开 `reuse` 不出错、也复用不上，v4 / v5 同样）；② 池内空闲上限沿用 v4 池的 15 秒（参考实现 180 秒，靠网卡变化时清池兜底，这里没有这个信号）。
- `core/Clash.Meta/docs/config.yaml`：Snell 示例补 v6（`mode`；v6 的 `obfs-opts` 被忽略）。
- 测试：`transport/snell/v6_golden_test.go`（20 个 PSK 的整形参数、三种模式按固定脚本写出的完整字节流，逐字节对参考实现的输出）；`v6_test.go`（进程内假服务端：三种模式的往返、record 边界、半关闭 / EOF、复用、UDP）；`v6_outbound_test.go`（经出站：配置校验、复用只拨一次；设 `SNELL_LIVE=<服务端地址>` 时对真实服务端跑 GET / 8MiB 下载 / 上传 / 复用 / UDP，带 v4、v5 回归，其余环境变量见文件内注释）。

## 2026-10-14 · Android 安装包同时带 v1 签名
- `android/app/build.gradle.kts`：发布签名配置显式 `enableV1Signing = true`、`enableV2Signing = true`。`minSdk = 26` 时 AGP 默认只签 v2，包里没有 `META-INF/*.SF`、`*.RSA`；OPPO / realme / 一加（ColorOS）的安装器自己先找这些文件，找不到就报「解析失败：安装包没有签名文件」（Parsing failed: APK contains no signature files），不交给系统去验 v2。签名证书不变，可以覆盖安装旧版本。从导入 Bettbox 起每个版本都是这样，0.2.6 及以前的包在这类机器上装不了。

## 2026-10-14 · 主控域名直连
- `lib/state.dart patchRawConfig`：规则前置那一行把各订阅档的地址传给 `meowPrependRules`（`subscriptionUrls: config.profiles.map((p) => p.url)`）。前置规则最前面多一组主控直连：登录了的主控域名，加上本机订阅里形如主控订阅地址（`/x/…`、`/api/clash/subscribe` 等）的那些域名（主控的「订阅域名」），主控是 IP 时用 `IP-CIDR(6)…,no-resolve`。原因：开着代理时，客户端访问主控（账户订阅列表、奖牌 / 解锁、白名单 token）按订阅规则分流、多半被分到节点上，有的节点连不上主控，用户实报「开了代理拉账户订阅一直超时，关代理正常」；主控生成的订阅里不带这条规则。规则本身与登录后重新套用配置都在 `lib/meowx/`（`config/meow_patch.dart panelDirectRules`、`panel/account.dart`）。只在规则模式下生效。

## 2026-10-14 · 拉订阅加超时，经内核失败时直连重试

- `lib/common/request.dart`：拉订阅的 `_clashDio` 原来没有任何超时，请求挂住就永远不结束，`AppController.updateProfile` 的防重入标记（`_updatingProfileIds`）一直不清，之后点「刷新」全部直接返回（用户在 Windows 上报「刷新订阅没反应、内容不更新」；启动时的自动更新挂住也会这样）。加了超时：连接 / 发送 15s、两次收到数据之间 30s。
- 同一处：内核起着时订阅请求先经本机混合端口走规则 / 当前节点（`BettboxHttpOverrides.handleFindProxy`）；节点连不上（全局模式、或被分到坏节点）时，网络层失败（超时 / 连不上，不含 4xx / 5xx）就用直连客户端再试一次，还拉不到才把错误报上去。内核没起时本来就直连，不重试。

## 2026-10-17 · 网络测速
- 新增 `core/Clash.Meta/component/speedtest`（内核包）：经选定**节点**直接拨号（`proxy.DialContext`，不经分流规则）连测速服务器，测延迟 → 下载 10 秒 → 上传 10 秒，单线程或 8 线程；四个测速源 Google / Apple / Speedtest / Cloudflare；字节记进 mihomo 流量统计。
- `core/meow_speedtest.go`、`core/constant.go`、`core/action.go`：桥层加 `meowSpeedTestStart` / `meowSpeedTestStatus` / `meowSpeedTestStop` 三个方法；`lib/enum/enum.dart`、`lib/models/generated/core.g.dart` 加对应的 `ActionMethod`。

## 2026-10-17 · 安卓页面切换动画换成 FlClash 0.9.1 的做法
- `lib/common/navigator.dart`：移动端 push 用 `MeowPageRoute`（`lib/meowx/app/page_route.dart`），删掉 `_CleanCupertinoPageRoute`；桌面端 `CommonDesktopRoute` 不变。
- `lib/application.dart`：安卓的 `PageTransitionsTheme` 换成 `MeowPageTransitionsBuilder`，其余平台仍是 Cupertino。
- 路由动画移植自 FlClash 0.9.1（chen08209/FlClash，GPL-3.0）的 `lib/ui/page_transition.dart` 与 `deferred_push.dart`，文件头保留出处：共享 X 轴平移（450ms、滑 25%），淡入淡出用「在页面上盖一层底色」代替透明图层（Impeller 下 Opacity 每帧一次离屏合成）；push 晚一帧开始，新页面第一帧的构建不挤进动画第一帧。原来的 Cupertino 路由每帧给下层页面画阴影与视差。

## 2026-10-17 · 底栏液态玻璃换成 FlClash 0.9.1 的实现
- `lib/main.dart`：去掉 liquid_glass_widgets 的初始化与全局包装（`LiquidGlassWidgets.initialize` / `wrap` / 自适应档位），`runApp` 回到 `ProviderScope(child: Application())`。
- `pubspec.yaml`：去掉 `liquid_glass_widgets` 依赖；`flutter: shaders:` 登记 `shaders/liquid_glass.frag`。
- 新底栏与玻璃都在 `lib/meowx/`：`glass/liquid_glass.dart`、`glass/liquid_glass_capture.dart`、`app/meow_dock.dart` 与 `shaders/liquid_glass.frag` 移植自 FlClash 0.9.1（chen08209/FlClash，GPL-3.0），文件头保留出处。原因：旧库每帧对底栏背后的全分辨率画面做一次大半径模糊再跑折射着色器，背后内容一动（切页、展开代理组、滚动）每帧都要重做，模拟器实测每帧光栅 60–140ms；FlClash 的做法是合成时把背后画面按模糊半径缩小（最多 1/8）重放到一张小图上、所有玻璃共用，画面不动就复用，同样的操作降到 3–5ms。

## 2026-10-18 · 液态玻璃主题 + 卡片 / 启动卡片 / 强调色
- `lib/application.dart`：两份主题按「我的 › 外观」的主题风格 / 玻璃样式 / 卡片颜色 / 启动卡片颜色 / 强调色推 token（`_themes.of(look: ref.watch(meowLookProvider))`，只这几项变才重建）；液态玻璃的宿主 `MeowGlassHost`（`lib/meowx/app/glass_host.dart`）包在 Navigator 外面，底栏与从根 Navigator 弹出的菜单 / 设置卡片共用一次截图（原来宿主在壳里，弹出层读不到背后的页面）。
- `lib/models/meow.dart MeowSettings`：`themeStyle`（经典 / 液态玻璃，缺省经典）、`glassTint`（透明 / 着色）、`cardColor`、`heroColor`、`accentColor`（ARGB，缺省白 / 樱粉 / 玫红 = 改版前的样子）；旧数据缺字段取缺省。
- `shaders/liquid_glass.frag`：Impeller 的 OpenGL ES 后端采样纹理时 y 轴是反的（dart:ui `ImageFilter.shader` 的说明），原着色器没处理，Android GLES 上每块玻璃读的是截图里上下颠倒的位置（同一层有两块以上时读到别人那块）；采样前在 `IMPELLER_TARGET_OPENGLES` 下翻转 y。底栏的底色 95% 不透明，以前看不出来。
- 其余在 `lib/meowx/`：token 推导（`theme/tokens.dart`）、玻璃控件（`theme/glass.dart`）、移植自 FlClash 0.9.1 的 iOS 风格取色器（`theme/color_picker.dart`）、外观设置行（`pages/me/appearance_parts.dart`）。

## 2026-10-18 · 可选 App 图标（只 Android）
- `AndroidManifest.xml`：加两个默认停用的 `activity-alias`（`MainActivityMDark` / `MainActivityMLight`，M 猫脸深 / 浅，intent-filter 照抄 MainActivity：LAUNCHER / 磁贴长按 / 深链）。默认图标仍是 MainActivity 自己的 LAUNCHER，升级不换启动入口。
- `plugins/AppPlugin.kt`：`app` 通道加 `getAppIcon` / `setAppIcon`（五个 LAUNCHER 组件开一个关其余，`DONT_KILL_APP`，当前值以 PackageManager 为准）；Bettbox 原有的 `setLauncherIcon`（高级 › 主题 › 深色图标）改走同一个函数，切回猫娘时会顺带关掉 M 图标的 alias。
- `services/NotificationComponentCache.kt`：M 图标开着时通知点开那个 alias（MainActivity 此时是停用的）。
- 资源：`scripts/make-brand-assets.py` 由 `design/brand/icon-m-{dark,light}.png` 生成自适应图标（底色背景层 + 缩进 66dp 安全圆的前景层 + 单色层）与设置页缩略图 `assets/images/app_icon_m_*_256.png`。
- 界面在 `lib/meowx/`：`state/app_icon.dart`、外观里的「App 图标」行（`pages/me/appearance_parts.dart`）。

## 2026-10-20 · 测速：指针码表 + 出口 ASN
- `core/Clash.Meta/component/speedtest`（我们加的内核包）：测速准备阶段经所选出站（不过规则）并行请求 `https://speed.cloudflare.com/meta`（要带 `Referer: https://speed.cloudflare.com/`，否则 403 + `{}`），限时 5 秒，取 clientIp / asn / asOrganization / country 写进进度（`exit` / `exitPending` 两个字段，旧界面忽略）；查不到只记日志、不影响测速（`exit.go`，测试 `exit_test.go`）。
- 界面只在 `lib/meowx/`：测速页读数换成 270° 指针码表（`pages/speedtest/speed_test_page.dart`），节点行挪到码表上方并显示出口，测速记录存出口并在详情显示（`state/speed_test.dart`、`pages/speedtest/speed_test_history_page.dart`）。

## 2026-10-20 · 测速：每条连接上做 HTTP/1.1 流水线
- `core/Clash.Meta/component/speedtest`（我们加的内核包）：下载 / 上传阶段每条测速连接自己经出站拨号 + TLS（校验证书，只协商 http/1.1），在这条连接上手写 HTTP/1.1 流水线，始终多一个请求在路上（深度 2，与 iOS / macOS 一致）；上传不等响应就发下一段。原来用 net/http 的 `client.Do` 循环，每到段边界（每段 25–32MB）下行停一个 RTT、随后突发，单线程逐格速率呈锯齿（用户反馈「中间几秒网速下降」）。单线程 = 1 条 TCP、多线程 = 8 条不变（`pipeline.go`，测试 `pipeline_test.go`）。

## 2026-10-20 · 自定义规则（直连 / 代理 / 拒绝）
- `lib/state.dart patchRawConfig`（三处）：
  - 写回规则表那一行改成调 `meowRuleTable`（`lib/meowx/config/meow_patch.dart`），多传 `quicRules` 与要交给内核的那份配置的 `proxy-groups`、订阅规则（`proxyGroups:` / `rules:`）；整张表的顺序 = 阻止 QUIC → po0 直连 → 绕过代理 → 推送直连 → 自定义规则 → 主控直连 → 订阅规则（主控直连让给自定义规则：直连连不上主控的网络里用户要能把主控域名指给代理组）。自定义规则排在绕过代理 / 推送直连之后（同 iOS：绕过表与推送直连先于全部规则判断，用户开着的这两项不被自定义规则盖掉），只在规则模式生效。「代理」按 `rules`（不含阻止 QUIC 的规则）与代理组推断主代理组（兜底 MATCH 指向的组；指向 DIRECT / REJECT 或没有 MATCH 时第一个 select 组；再没有用 GLOBAL 或第一个代理组；一个代理组都没有 = 不生成「代理」规则，交给订阅规则）。
  - 「阻止 QUIC」的 REJECT 规则不再并进 `rules`（`rules = [...quicRules, ...rules]` 删掉，`quicRules` 提到 if 外面），改由上面那一行排在全部 MeowX 前置规则之前：否则自定义规则命中的域名（直连 / 代理都支持 UDP）的 QUIC 照样发出去。副作用：绕过代理、推送直连、主控直连、po0 直连的 UDP 443 也被丢，与 iOS 一致（iOS 在收包处就丢 UDP 443、先于一切规则）；主控与 po0 的上报走 TCP，不受影响。
  - 写回规则表前多一行 `captureMainProxyGroup`（当前订阅才记，同 `captureNodeKeys`）：记下按交给内核的那份配置（Bettbox 规则覆写、停用组改 PASS 之后）算出的主代理组，界面上「代理（组名）」优先用它；多一行 import `meowx/state/custom_rules.dart`。
- `lib/models/meow.dart MeowSettings`：`customRules`（`MeowCustomRule{value, match: domain|suffix|ip, action: direct|proxy|reject}`，列表顺序即优先级；旧数据没有这个字段 = 空，认不出的枚举回到缺省）。
- 其余在 `lib/meowx/`：规范化 / 主代理组推断 / 规则生成（`state/custom_rules.dart`，域名出 `DOMAIN` / `DOMAIN-SUFFIX`，IP 出 `IP-CIDR(6),…/32|/128,…,no-resolve`；域名标签允许 `_`、IPv6 统一成标准写法、IPv4-mapped 转 IPv4，上限 1000 条）、「我的 › 设置 › 流量控制 › 自定义规则」子页（`pages/settings/custom_rules_page.dart`）、动态页连接详情的「这个域名走：直连 / 代理 / 拒绝」（`pages/connections/conn_rule_card.dart`，点了把这条挪到最前、立即生效）。改了规则时连着就 `applyProfileDebounce` 重新套用配置（同绕过代理）。与 iOS / macOS 同一功能、同一口径。

## 2026-10-21 · TLS 依赖与 Go 版本（安全更新）
- `core/Clash.Meta/go.mod`、`core/go.mod`（及 go.sum）：`github.com/metacubex/tls` v0.1.8 → v0.1.9，同上游 mihomo「fix: CVE-2026-97031 for crypto/tls」。mihomo 用的是这份 crypto/tls 的副本，升 Go 修不到它。
- `.github/workflows/build.yaml`：`GO_VERSION` 1.25.x → 1.26.10（CVE-2026-111943：旧版 crypto/x509 仍接受已被撤销信任的中间 CA 签的证书，1.25 不再出修复）。

## 2026-10-22 · 内核同步上游 mihomo v1.19.33
- `core/Clash.Meta/`：底子从上游 mihomo Alpha 的 fbb67422（2026-09-16，介于 v1.19.31 与 v1.19.32 之间，即 Bettbox v1.19.2 带来的那份）换成 **v1.19.33** 标签（26 个上游提交：tun `dns-mode`、sudoku 重构、openvpn / loadbalance 修复等）。做法：在上游历史上把「Bettbox 对上游的补丁」（Android 相关的 patch*.go、features/android.go 等约 40 个文件）与「本项目对 Bettbox 的修改」（Miu、Snell v6、AnyTLS + REALITY、测速包、tls v0.1.9 等）两个提交依次重放到 v1.19.33 上；只有 go.mod / go.sum 冲突，取上游版本（上游已是 `metacubex/tls` v0.1.9、`utls` v1.8.8）。
- `core/go.mod`、`core/go.sum`：随内核 `go mod tidy`。
- 验证：android/arm64、windows/amd64、linux/amd64、darwin/arm64 交叉编译通过；`transport/miu`、`transport/snell`、`component/speedtest`、`adapter/outbound`、`config`、`rules`、桥接层 `core` 测试通过。

## 2026-10-22 · Android 用几小时后断网（三星 One UI 实报，同机 NekoBox 正常）
- 新增 `core/third_party/sing-tun`（vendored `metacubex/sing-tun` v0.4.28，GPL-3.0，`core/go.mod` 用 replace 引入）：只改 `stack_system.go` 的 `acceptLoop`——上游 Accept 出任何错就退出，此后经 TUN 的 TCP 全部挂住（DNS / UDP 照常），要关掉重开重建栈才恢复；改成监听关闭或 ctx 取消才退出，其它错误（如 fd 用尽）记日志、退避后继续。附单测 `meow_accept_test.go`。mixed 栈的 TCP 与 Windows 都走这份。
- `core/Clash.Meta/component/keepalive/tcp_keepalive.go`：Android 上不再强制关闭 TCP keepalive（上游为省电一律关），idle / interval 不低于 60 秒；换网 / NAT 超时死掉的连接能被发现、释放。
- 换网重置：新增 `android/.../services/UnderlyingNetworkTracker.kt`（VPN 建好时由 `BettboxVpnService` 启动、stop 时停）跟踪最佳非 VPN 网络，变了就 `setUnderlyingNetworks`，换成另一个网络时去抖 1 秒调 `Core.onUnderlyingNetworkChanged`（`core.cpp` JNI → `core/meow_netreset_android.go` 的 `networkChanged`）：清网卡缓存、DNS 上游连接与缓存、统计表里全部连接、各协议空闲连接池，再重测自动组。以前只有系统 DNS 字符串变了才通知内核，Wi-Fi 与移动数据同时在线时来回切往往不变。新增 `core/Clash.Meta/component/netreset` 钩子，Miu 空闲通道（`transport/miu/client.go`）与 Snell v6 复用池（`transport/snell/v6.go`、`v6_reuse.go` 的 `closeIdle`）接上。
- 拣选上游 Bettbox `60c9862e`（Improve Android service lifecycle）的一部分：`VpnPlugin.kt` 连上后 `startStickyService`（VPN 服务成为 started + START_STICKY，被系统杀掉后拉起并以 quick 参数重连）、`restoreNotification` 改成直接调服务方法（`ServicePlugin.kt` / `BettboxVpnService.kt`）、`core/lib_android.go` 的 quickStart 初始化失败后 return。MainActivity 的高刷新率改动没拣。
- `lib/meowx/state/battery_prompt.dart` + `app/meow_root.dart`：Android 第一次连上后，App 不在「忽略电池优化」白名单里就提示一次（附三星「永不休眠的应用」「电池 › 不受限制」的设置位置），只提示一次。

## 2026-10-27 · Wi-Fi 智能开关（只 Android）
- 新增 `plugins/wifi_ssid`：移植自 FlClash 的同名插件（MIT，© 2025 FlClash，LICENSE 随插件），只保留 Android。读 SSID（Android 12+ 经带 `FLAG_INCLUDE_LOCATION_INFO` 的 Wi-Fi 网络回调取 `WifiInfo`，更早的系统用 `WifiManager`）与定位权限申请（前台 → 后台「始终允许」分两步）原样保留；MeowX 加了 `getNetworkState`（非 VPN 网络里有没有 Wi-Fi / 蜂窝 / 有线、精确 / 后台定位权限、定位服务开关）、`openAppSettings`、`openLocationSettings`。插件清单经清单合并给 App 加上 `ACCESS_WIFI_STATE`、`ACCESS_COARSE_LOCATION`、`ACCESS_FINE_LOCATION`、`ACCESS_BACKGROUND_LOCATION`（App 自己的 AndroidManifest 没改）。
- `pubspec.yaml`：加 `wifi_ssid`（path 依赖）。
- `android/.../plugins/VpnPlugin.kt handleSmartStop`：暂停时的 Toast 由「Bettbox Suspended」改成「MeowX 已暂停代理」（Wi-Fi 规则断开时用户会看到它）。
- `lib/models/meow.dart MeowSettings`：`wifiSwitchEnabled`、`wifiRules`（`MeowWifiRule{ssid, action}`）、`wifiOtherAction`（`MeowWifiAction`：不变 / 连接代理 / 断开代理，缺省连接）。
- 其余在 `lib/meowx/`：规则判定与执行（`state/wifi_switch.dart`）、「我的 › Wi-Fi 智能开关」页（`pages/settings/wifi_switch_page.dart`，手机是入口行、宽屏是一个分组）、`app/meow_root.dart` 接线、首页主卡的「已暂停」、电源键在暂停中点 = 恢复（`state/connection.dart`）。断开 / 连接复用 Bettbox 已有的智能启停（`smartStop` / `smartResume`，VPN 服务留着、核心挂起）：规则只暂停 / 恢复正在用的代理，不打开用户自己关掉的；打开本功能时关掉「高级」里 Bettbox 按 IP / 网关的「智能启停」（两者共用一个暂停状态）。与 iOS / macOS 的 Wi-Fi 规则同一思路：SSID 第一条命中，其余走「其它网络」，只在网络变化时触发，手动开关后换网前不再干预；读不到 SSID 时不切换并写明原因。
