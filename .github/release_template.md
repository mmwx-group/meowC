## MeowX VERSION

| 平台 | 下载 |
|:---|:---|
| Android（arm64，推荐） | [MeowX-VERSION-android-arm64-v8a.apk](https://github.com/mmwx-group/meowC/releases/download/vVERSION/MeowX-VERSION-android-arm64-v8a.apk) |
| Android（通用，含 arm / x86_64） | [MeowX-VERSION-android-universal.apk](https://github.com/mmwx-group/meowC/releases/download/vVERSION/MeowX-VERSION-android-universal.apk) |
| Windows（x64，安装包） | [MeowX-VERSION-windows-amd64-setup.exe](https://github.com/mmwx-group/meowC/releases/download/vVERSION/MeowX-VERSION-windows-amd64-setup.exe) |
| Windows（x64，便携版 zip） | [MeowX-VERSION-windows-amd64-portable.zip](https://github.com/mmwx-group/meowC/releases/download/vVERSION/MeowX-VERSION-windows-amd64-portable.zip) |
| Linux（x64，deb） | [MeowX-VERSION-linux-amd64.deb](https://github.com/mmwx-group/meowC/releases/download/vVERSION/MeowX-VERSION-linux-amd64.deb) |
| Linux（arm64，deb） | [MeowX-VERSION-linux-arm64.deb](https://github.com/mmwx-group/meowC/releases/download/vVERSION/MeowX-VERSION-linux-arm64.deb) |
| Linux（x64，AppImage） | [MeowX-VERSION-linux-amd64.AppImage](https://github.com/mmwx-group/meowC/releases/download/vVERSION/MeowX-VERSION-linux-amd64.AppImage) |
| Linux（arm64，AppImage） | [MeowX-VERSION-linux-arm64.AppImage](https://github.com/mmwx-group/meowC/releases/download/vVERSION/MeowX-VERSION-linux-arm64.AppImage) |

Windows 安装包未做代码签名，SmartScreen 提示时选「更多信息 → 仍要运行」。

Linux：deb 支持 Ubuntu 22.04+ / Debian 12+，`sudo apt install ./MeowX-VERSION-linux-amd64.deb` 安装（自动装好依赖，虚拟网卡 TUN 装完即可用）；AppImage 免安装（`chmod +x` 后直接运行，需要 libfuse2），只能用系统代理、不能开 TUN。

源码：<https://github.com/mmwx-group/meowC>（GPL-3.0，基于 Bettbox / mihomo）
