# NOTICE

MeowX（Android / Windows 客户端）以 GNU General Public License v3.0 发布，完整许可证见 `LICENSE`。

本项目基于以下开源项目修改而来，均为 GPL-3.0：

- **Bettbox** v1.19.2（commit `b2d8734`）— https://github.com/appshubcc/Bettbox
  本仓库的首个提交即 Bettbox 的原样快照；之后的全部修改记录在 `CHANGES-FROM-BETTBOX.md`。
- **FlClash** — https://github.com/chen08209/FlClash（Bettbox 的上游）
- **mihomo**（Clash Meta 内核）— https://github.com/MetaCubeX/mihomo（`core/Clash.Meta/` 为其快照拷贝）

原作者的版权声明与文件头一律保留。

新增的第三方依赖：`cryptography`（Apache-2.0，面板加密通道）。

`plugins/wifi_ssid`（读 Wi-Fi 名称，Wi-Fi 智能开关用）移植自 FlClash 的同名插件，MIT，© 2025 FlClash，许可声明见该目录的 `LICENSE`。

`liquid_glass_widgets` 1.7.2（MIT，© 2024–2026 Sebastian Degenaar；手机底栏的液态玻璃），其中内含 `liquid_glass_renderer` 0.2.0-dev.4（MIT，© 2025 Tim Lehmann / whynotmake.it）与 `motor` 1.1.0（MIT）的代码，版权与许可声明随包的 LICENSE / THIRD_PARTY_NOTICES 一并分发；`cupertino_icons`（MIT，该库需要）。

MeowX 的 iOS / macOS 客户端是独立的闭源代码库，与本仓库不共享任何源码；本仓库只复刻其界面与面板协议。
