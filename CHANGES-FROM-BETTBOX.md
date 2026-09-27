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
- `lib/application.dart`：`home` 由 Bettbox `HomePage` 换成 `lib/meowx/app/meow_root.dart` 的 `MeowRoot`（手机底部 5 Tab / 宽屏左侧图标栏），主题改为 `meowThemeData`（系统蓝强调色 + MM token，不再动态取色）。Bettbox 原页面经「设置 → 高级」`ToolsView` 原样进入；Bettbox 内部 `toPage(PageLabel)` 经 `currentPageLabelProvider` 映射到 Tab 或 push。
- `lib/models/config.dart`：`Config` 增加 `meow: MeowSettings`（`lib/models/meow.dart`，MeowX 自己的设置：DNS 模式 / 测速方式 / 节点卡片档位 / 同步间隔 / 覆写 / 本地代理 / 账户）；`openLogs` 默认 `false`，`safeFromJson` 不再强制打开日志流。
- `lib/providers/state.dart`：`configState` 纳入 `meow`，随 Bettbox 偏好一起落盘。
- 新增 `lib/meowx/`：主题 token / GlassCard / LatencyChip / TypeBadge / PageTitle / IconRail / TwoPane / Sparkline；首页、代理页、设置页（P1）；连接页与配置页暂时嵌入 Bettbox 原视图（P2 替换）。

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
- `lib/manager/app_manager.dart`：关掉 Bettbox 桌面侧栏（MeowX 壳自带图标栏）。
- 首页（仅 Windows）：网速图位置换成「接管方式」卡（TUN / 系统代理，开关沿用 Bettbox 的 provider）。

## 2026-09-27 · 悬空规则引用不再废掉整份配置
- 新增 `core/meow_rules.go`（+ `core/meow_rules_test.go`）：`meowSanitizeDanglingRules` 在 `UnmarshalRawConfig` 之后、`ParseRawConfig` 之前，把引用了配置里不存在的出站的规则改成 `PASS`、引用了不存在 rule-provider 的规则删掉（子规则同理），并写 warn 日志。
- `core/hub.go handleValidateConfig`：由 `config.Parse` 改为 `UnmarshalRawConfig` → 消毒 → `ParseRawConfig`，让导入校验与实际应用同一套宽容度。
- `core/common.go setupConfig`：`ParseRawConfig` 前同样消毒。
