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
- `lib/common/request.dart`、`lib/controller.dart`：手动检查更新区分「已是最新」与「检查失败」（`manualCheckUpdate`）；新版本弹窗写明当前版本与安装包（文件名 · 大小），Android 按钮为「下载 APK」。
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
- 新增 `core/meow_po0.go`：`meowPo0Report` action——用 mihomo 直连 dialer（与 DIRECT 出站同一条路，Android 经 socket protect 出 VPN、Windows TUN 经 sing-tun 绑物理网卡）向 po0 服务器 POST 空 body、跳过证书校验、10s 超时，逐 url 返回状态码与响应体；`core/constant.go` / `core/action.go` 登记该方法。
- `lib/enum/enum.dart`（`ActionMethod.meowPo0Report`）与生成文件 `lib/models/generated/core.g.dart`（枚举映射手动补一行，与 build_runner 输出一致）。
- 上报调度在 `lib/meowx/state/po0_reporter.dart`（登录 / 启动后、`refreshExtras`、网络变化（`connectivity_plus`）、每 10 分钟），列表模型在 `lib/meowx/panel/po0.dart`。
- `lib/models/meow.dart MeowSettings`：新增 `po0Enabled`（默认 false）与 `po0DirectIps`（最近一次 po0 服务器 IP 缓存；开关打开时经 `meowPrependRules` 在规则最前加 `IP-CIDR(6),<ip>,DIRECT,no-resolve`，列表变化时与其它覆写同样 `applyProfileDebounce` 热生效）；设置页「订阅」组加「po0 加白」开关，所有上报入口（启动 / 登录 / refreshExtras / 定时 / 网络变化）以它为准。

## 2026-10-08 · 界面性能
这一轮只改 MeowX 自己的界面层（`lib/meowx/**`）；Bettbox 的底层代码只动了两处一行级的 bug 修复和两处已有的 MeowX 接入点：
- `lib/clash/lib.dart`：`_waitForIpc` 超时后不再把还没完成的 `_canSendCompleter` 换掉——换掉的话 `preload()` / `sendMessage()` 早先拿到的 future 永远不完成，慢机器上服务引擎 2 秒没连上会永远停在启动页。
- `lib/clash/interface.dart`：`handleResult` 取 completer 时即从 `callbackCompleterMap` 移除（原来只 complete 不移除，要等 30s 后的清理定时器，每秒一份的连接快照被多留 30 秒）。
- `lib/application.dart`：亮 / 暗两份主题走缓存（`MeowThemes`），无关的重建不再触发 200ms 主题插值。
- `lib/views/about.dart`：关于页的图标用 256 的小图。
- 界面层：隐藏的 Tab 页不再跑动画 / 不再随每秒数据重建（`MeowTabStack`、`watchOnTab`）；连接快照共用一份、没有界面显示连接数时不拉（`ConnStatsController`）；点节点 / 换组不再让核心重解析整份订阅（`profileRawConfigProvider` 只盯 lastUpdateDate / ageSecretKey）；线性图标直接画路径（不再 SvgPicture.string + colorFilter）等。
- 没合进来、留在 `perf/*` 分支上的底层改动（要动 Bettbox 的核心通信 / 控制器 / 启动 / 托盘，Windows 部分本机无法验证）：大回包后台解码、刷新代理组后台解码与摘要比较、Windows 主窗口提前显示、托盘菜单按需重建、首帧前初始化延后、偏好落盘去重、液态玻璃自适应降档。
