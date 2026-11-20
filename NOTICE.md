# NOTICE

MeowX（Android / Windows 客户端）以 GNU General Public License v3.0 发布，完整许可证见 `LICENSE`。

本项目基于以下开源项目修改而来，均为 GPL-3.0：

- **Bettbox** v1.19.2（commit `b2d8734`）— https://github.com/appshubcc/Bettbox
  本仓库的首个提交即 Bettbox 的原样快照；之后的全部修改记录在 `CHANGES-FROM-BETTBOX.md`。
- **FlClash** — https://github.com/chen08209/FlClash（Bettbox 的上游）
- **mihomo**（Clash Meta 内核）— https://github.com/MetaCubeX/mihomo（`core/Clash.Meta/` 是子模块 https://github.com/mmwx-group/meowx-core，即本项目修改过的 mihomo，与 OpenWrt 版共用）

原作者的版权声明与文件头一律保留。

新增的第三方依赖：`cryptography`（Apache-2.0，面板加密通道）。

`plugins/wifi_ssid`（读 Wi-Fi 名称，Wi-Fi 智能开关用）移植自 FlClash 的同名插件，MIT，© 2025 FlClash，许可声明见该目录的 `LICENSE`。

`liquid_glass_widgets` 1.7.2（MIT，© 2024–2026 Sebastian Degenaar；手机底栏的液态玻璃），其中内含 `liquid_glass_renderer` 0.2.0-dev.4（MIT，© 2025 Tim Lehmann / whynotmake.it）与 `motor` 1.1.0（MIT）的代码，版权与许可声明随包的 LICENSE / THIRD_PARTY_NOTICES 一并分发；`cupertino_icons`（MIT，该库需要）。

`lib/meowx/theme/droplet_morph.dart`（弹出菜单 / 气泡的水滴变形）的曲线常数与公式移植自 `liquid_glass_widgets` 1.18 的 `lib/utils/liquid_morph_physics.dart`（MIT，© 2024–2026 Sebastian Degenaar）：

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

MeowX 的 iOS / macOS 客户端是独立的闭源代码库，与本仓库不共享任何源码；本仓库只复刻其界面与面板协议。
