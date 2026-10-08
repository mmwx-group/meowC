# MeowX 界面重设计（Android + Windows）

设计画布：https://claude.ai/artifact/38dW3AVAMm5xVu1VTr5zGa （私有，需要在页面的 Share 菜单里分享后别人才能打开）

对齐 iOS / iPad 的改版（MeowX 仓库 `Design/ui-redesign/`）：奶白 / 樱粉 / 墨色主题，五个 Tab 并成四个（首页 / 节点 / 动态 / 我的）。

- `canvas.json`：画布索引（每张画板的位置与尺寸）
- `boards/*.dc.html`：画板源码（设计画布的 `.dc.html` 格式）。`A*` / `Main` = Android 手机 412×892，`W*` = Windows 1100×720
- `assets/`：画板里引用的两张品牌图。画板源码里写的是画布上的资产地址：
  `/_blob/618ef02428a266b2c495af9b06f888be` = `art-light.png`，`/_blob/0d9f9a6adebe8f94f9e5a6c2eae537cf` = `art-dark.png`

本地预览（不依赖 claude.ai，任何浏览器直接打开）：

```sh
python3 design/ui-redesign/build-preview.py   # 生成 design/ui-redesign/preview.html
open design/ui-redesign/preview.html
```

状态：已实现（`lib/meowx/**`）。与画板的出入：Windows 保留全局 40 高的窗口标题栏（窗口按钮没有并进各页标题行）；Android 底栏沿用液态玻璃（`liquid_glass_widgets`），没有换成画板里的纯色胶囊。
