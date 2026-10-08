# MeowX 界面重设计（Android + Windows）

设计画布：https://claude.ai/artifact/38dW3AVAMm5xVu1VTr5zGa （私有，需要在页面的 Share 菜单里分享后别人才能打开）

对齐 iOS / iPad 的改版（MeowX 仓库 `Design/ui-redesign/`）：奶白 / 樱粉 / 墨色主题，五个 Tab 并成四个（首页 / 节点 / 动态 / 我的）。

- `canvas.json`：画布索引（每张画板的位置与尺寸）
- `boards/*.dc.html`：画板源码（设计画布的 `.dc.html` 格式）。`A*` / `Main` = Android 手机 412×892，`W*` = Windows 1100×720
- `assets/`：画板里引用的两张品牌图。画板源码里写的是画布上的资产地址：
  `/_blob/618ef02428a266b2c495af9b06f888be` = `art-light.png`，`/_blob/0d9f9a6adebe8f94f9e5a6c2eae537cf` = `art-dark.png`

状态：设计稿，尚未实现。
