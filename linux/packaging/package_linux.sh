#!/usr/bin/env bash
# MeowX Linux 打包：把 `flutter build linux --release` 的产物打成 deb 与 AppImage，放到 dist/。
#
# 用法：linux/packaging/package_linux.sh <amd64|arm64> [--no-appimage]
# 前置：已经 `dart setup.dart linux --arch <arch> --out core-only` + `flutter build linux --release`；
#       打 AppImage 要 PATH 里有 appimagetool（CI 里现下载，见 build.yaml）。
#
# 安装布局（deb）：程序目录 /usr/share/meowx/（MeowX 主程序 + MeowXCore 内核 + data/ + lib/），
# /usr/bin/meowx 指向主程序，桌面入口与图标按 freedesktop 规范放。
# 内核以 root 所有、带 setuid 装进去（4755）：开 TUN 要建网卡、改路由，这样装完就能开，不用每次输密码。
# 应用启动时检查的也是这个（lib/common/system.dart：属主 root 且带 s 位）。
# AppImage 是只读镜像，里面的内核没法 setuid：只能用系统代理，开 TUN 会提示没有管理员权限。
set -euo pipefail

ARCH="${1:?用法：package_linux.sh <amd64|arm64> [--no-appimage]}"
WITH_APPIMAGE=1
[[ "${2:-}" == "--no-appimage" ]] && WITH_APPIMAGE=0

case "$ARCH" in
  amd64) FLUTTER_ARCH=x64; APPIMAGE_ARCH=x86_64 ;;
  arm64) FLUTTER_ARCH=arm64; APPIMAGE_ARCH=aarch64 ;;
  *) echo "未知架构：$ARCH" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="$(sed -nE 's/^version:[[:space:]]*([^+[:space:]]+).*/\1/p' pubspec.yaml)"
[[ -n "$VERSION" ]] || { echo "pubspec.yaml 里没找到 version" >&2; exit 1; }
BUNDLE="build/linux/$FLUTTER_ARCH/release/bundle"
[[ -x "$BUNDLE/MeowX" ]] || { echo "没找到 $BUNDLE/MeowX：先跑 flutter build linux --release" >&2; exit 1; }
[[ -f "$BUNDLE/MeowXCore" ]] || { echo "没找到 $BUNDLE/MeowXCore：先跑 dart setup.dart linux --arch $ARCH --out core-only" >&2; exit 1; }

APP_ID="com.miaomiaowux.app"
ICON="assets/images/icon_256.png"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DIST"

# 桌面入口：Exec 由调用方给（deb 写 /usr/bin/meowx，AppImage 写主程序名）
desktop_entry() {
  cat <<EOF
[Desktop Entry]
Type=Application
Name=MeowX
GenericName=Proxy Client
GenericName[zh_CN]=代理客户端
Comment=MeowX proxy client
Comment[zh_CN]=MeowX 代理客户端
Exec=$1
Icon=meowx
Terminal=false
Categories=Network;
Keywords=proxy;vpn;clash;mihomo;
StartupNotify=true
StartupWMClass=$APP_ID
EOF
}

# ---------------------------------------------------------------- deb
PKG="$WORK/deb"
mkdir -p "$PKG/DEBIAN" "$PKG/usr/share/meowx" "$PKG/usr/bin" \
  "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE/." "$PKG/usr/share/meowx/"
chmod 4755 "$PKG/usr/share/meowx/MeowXCore"
ln -s ../share/meowx/MeowX "$PKG/usr/bin/meowx"
desktop_entry "/usr/bin/meowx" > "$PKG/usr/share/applications/meowx.desktop"
cp "$ICON" "$PKG/usr/share/icons/hicolor/256x256/apps/meowx.png"

INSTALLED_KB="$(du -sk "$PKG/usr" | cut -f1)"
# 运行时依赖：GTK 3（Ubuntu 24.04 起改名 libgtk-3-0t64）、托盘（ayatana appindicator）、全局快捷键（keybinder）、
# EGL / GLES（Flutter 引擎启动时 dlopen，ldd 查不出来；最小化系统没有就直接 abort）。Mesa 的驱动桌面都有，写成推荐
cat > "$PKG/DEBIAN/control" <<EOF
Package: meowx
Version: $VERSION
Architecture: $ARCH
Maintainer: MeowX <noreply@meowx.net>
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0t64 | libgtk-3-0, libayatana-appindicator3-1, libkeybinder-3.0-0, libegl1, libgles2
Recommends: libgl1-mesa-dri
Section: net
Priority: optional
Homepage: https://meowx.net
Description: MeowX proxy client
 Desktop client for MeowX: rule-based proxy with system proxy and TUN modes.
EOF
# 包里的属主一律 root（--root-owner-group），内核的 setuid 位随包装上；
# 有人在装好之后改过权限的话，装 / 升级时再兜底设一次
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
CORE=/usr/share/meowx/MeowXCore
if [ -f "$CORE" ]; then
  chown root:root "$CORE"
  chmod 4755 "$CORE"
fi
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q /usr/share/applications || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true; fi
exit 0
EOF
chmod 755 "$PKG/DEBIAN/postinst"
DEB="$DIST/MeowX-$VERSION-linux-$ARCH.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB"
echo "deb: $DEB"

# ---------------------------------------------------------------- AppImage
if [[ "$WITH_APPIMAGE" == 1 ]]; then
  APPDIR="$WORK/MeowX.AppDir"
  mkdir -p "$APPDIR/usr/share/meowx"
  cp -a "$BUNDLE/." "$APPDIR/usr/share/meowx/"
  desktop_entry "MeowX" > "$APPDIR/meowx.desktop"
  cp "$ICON" "$APPDIR/meowx.png"
  cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/share/meowx/MeowX" "$@"
EOF
  chmod 755 "$APPDIR/AppRun"
  APPIMAGE="$DIST/MeowX-$VERSION-linux-$ARCH.AppImage"
  # CI 里没有 FUSE：让 appimagetool 自己解开再跑
  ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 appimagetool --no-appstream "$APPDIR" "$APPIMAGE"
  echo "AppImage: $APPIMAGE"
fi
