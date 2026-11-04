#!/bin/zsh
# 一键准备 macOS（Apple Silicon）上的 Android 本机打包环境：Flutter 3.44.9、OpenJDK 17、Android SDK/NDK、Rust Android target。
# 全部装在用户目录与 Homebrew 下，不动系统。已装的组件会跳过。用法：./scripts/setup-android-env.sh [--emulator]
set -e
FLUTTER_VERSION=3.44.9
SDK=$HOME/Library/Android/sdk
FLUTTER_HOME=$HOME/.local/flutter
CLT=/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export HOMEBREW_NO_AUTO_UPDATE=1

echo "== Homebrew: openjdk@17 / android-commandlinetools"
brew list --formula openjdk@17 >/dev/null 2>&1 || brew install openjdk@17
brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools

echo "== Flutter $FLUTTER_VERSION → $FLUTTER_HOME"
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  mkdir -p "$HOME/.local"
  curl -L -o /tmp/flutter.zip "https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_${FLUTTER_VERSION}-stable.zip"
  unzip -q /tmp/flutter.zip -d "$HOME/.local" && rm /tmp/flutter.zip
fi
"$FLUTTER_HOME/bin/flutter" config --no-analytics --android-sdk "$SDK" >/dev/null

echo "== Android SDK → $SDK（sdkmanager 单线程下载偏慢，系统镜像 1.7GB 请耐心）"
mkdir -p "$SDK"
yes | "$CLT/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
PKGS=("platform-tools" "platforms;android-35" "build-tools;35.0.0" "ndk;28.2.13676358" "ndk;27.0.12077973")
[ "$1" = "--emulator" ] && PKGS+=("emulator" "system-images;android-35;google_apis;arm64-v8a")
"$CLT/sdkmanager" --sdk_root="$SDK" "${PKGS[@]}"

echo "== Rust Android target（code_forge 插件的 cargokit 需要）"
rustup target add aarch64-linux-android
NDK_BIN=$SDK/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin
grep -q "aarch64-linux-android" ~/.cargo/config.toml 2>/dev/null || cat >> ~/.cargo/config.toml <<CFG
[target.aarch64-linux-android]
linker = "$NDK_BIN/aarch64-linux-android26-clang"
[target.armv7-linux-androideabi]
linker = "$NDK_BIN/armv7a-linux-androideabi26-clang"
[target.x86_64-linux-android]
linker = "$NDK_BIN/x86_64-linux-android26-clang"
CFG

echo "== 内核子模块（core/Clash.Meta）"
git -C "$(dirname "$0")/.." submodule update --init

echo "== Go 模块预热（绕过本机代理，之后构建可离线）"
( cd "$(dirname "$0")/../core" && env -u http_proxy -u https_proxy -u all_proxy GOPROXY=https://proxy.golang.org,direct GOFLAGS=-mod=mod go mod download all )

echo "== android/local.properties"
LP="$(dirname "$0")/../android/local.properties"
grep -q "sdk.dir" "$LP" 2>/dev/null || echo "sdk.dir=$SDK" >> "$LP"
echo "完成。正式签名请把 keystore 放到 android/app/keystore.jks，并在 android/local.properties 追加 keyAlias / storePassword / keyPassword（二者已 gitignore）。"
echo "打包：./scripts/build-android.sh [arm64|universal]"
