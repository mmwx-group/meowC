#!/usr/bin/env bash
# Linux 冒烟测试（CI 里在干净的 ubuntu 容器中以 root 跑，见 build.yaml 的 Smoke Test）：
# 只靠 deb 声明的依赖装一遍，查内核是不是 root + setuid、有没有找不到的库；再在虚拟显示里起一次截图，并验深链：
#   开着时点深链 → 第二个进程经 GApplication 转给开着的那个就退出；没开着时 → 深链把 App 拉起来、网址随启动参数进去；
#   AppImage → 启动时把自己登记成深链处理程序。
# 用法：smoke_linux.sh <标签>；/dist 放 deb 与 AppImage，截图与日志写到 /smoke。
set -euo pipefail

TAG="$1"
OUT=/smoke

fail() {
  echo "$1"
  shift
  for f in "$@"; do echo "== $f"; tail -50 "$f" 2>/dev/null || true; done
  exit 1
}

# 第二段：在虚拟显示 + 会话总线里跑（下面装好包之后由本脚本自己调起）
if [[ "${2:-}" == "--display" ]]; then
  # 1. 正常启动
  meowx > "$OUT/$TAG-run.log" 2>&1 &
  pid=$!
  sleep 30
  import -window root "$OUT/$TAG.png"
  kill -0 "$pid" 2>/dev/null || fail "MeowX 没起来或中途退出：" "$OUT/$TAG-run.log"
  echo alive > "$OUT/$TAG-alive.txt"

  # 2. 开着时点深链：桌面入口登记了 scheme，第二个进程把网址转给开着的这个后退出（不开第二个窗口）。
  #    首次启动停在免责声明上、App 还没开始收深链：转来的这条要留到点了「同意」之后交出
  handler="$(xdg-mime query default x-scheme-handler/clash)"
  [[ "$handler" == meowx.desktop ]] || fail "clash:// 的处理程序是「$handler」，不是 meowx.desktop"
  timeout 20 xdg-open "clash://install-config?url=https%3A%2F%2Fexample.com%2Fsmoke.yaml" > "$OUT/$TAG-forward.log" 2>&1 \
    || fail "转交深链的进程没正常退出" "$OUT/$TAG-forward.log"
  sleep 2
  # 「同意」按钮：1440×900 的屏上窗口居中、对话框在正中，按钮在中心右下 (+121, +77)
  xdotool mousemove 841 527 click 1
  sleep 5
  import -window root "$OUT/$TAG-link.png"
  grep -q "onAppLink: clash://install-config" "$OUT/$TAG-run.log" \
    || fail "开着的 MeowX 没收到深链" "$OUT/$TAG-run.log" "$OUT/$TAG-forward.log"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  # 收掉所有 MeowX 进程（主程序经 /usr/bin/meowx 起、内核、解开的 AppImage）：命令行不分大小写匹配 meowx
  pkill -f -i meowx || true
  sleep 2

  # 3. 没开着时点深链：拉起 App（xdg-open 等程序退出才返回，放后台）
  xdg-open "miaomiaowu://login?host=127.0.0.1%3A9&code=smoke" > "$OUT/$TAG-cold.log" 2>&1 &
  sleep 30
  # 上一步点的「同意」要是没来得及落盘，这里又停在免责声明上：再点一次
  if ! grep -q "launchLink:" "$OUT/$TAG-cold.log"; then
    xdotool mousemove 841 527 click 1
    sleep 5
  fi
  import -window root "$OUT/$TAG-cold.png"
  grep -q "launchLink: miaomiaowu://login" "$OUT/$TAG-cold.log" \
    || fail "深链拉起的 MeowX 没拿到网址" "$OUT/$TAG-cold.log"
  pkill -f -i meowx || true
  sleep 2

  # 4. AppImage：启动时写一个只管深链的桌面入口到 ~/.local/share/applications（容器里没有 FUSE，解开再跑）
  APPIMAGE_EXTRACT_AND_RUN=1 /dist/MeowX-*-linux-*.AppImage > "$OUT/$TAG-appimage.log" 2>&1 &
  sleep 30
  entry="$HOME/.local/share/applications/meowx-appimage.desktop"
  [[ -f "$entry" ]] || fail "AppImage 没有登记深链处理程序" "$OUT/$TAG-appimage.log"
  cp "$entry" "$OUT/$TAG-appimage.desktop"
  handler="$(xdg-mime query default x-scheme-handler/miaomiaowu)"
  [[ "$handler" == meowx-appimage.desktop ]] || fail "miaomiaowu:// 的处理程序是「$handler」，不是 meowx-appimage.desktop"
  pkill -f -i meowx || true
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# 虚拟显示要 Mesa 的软件渲染；中文字体按普通桌面装上（App 另有随包的中文回落）；
# 深链要会话总线（GApplication 靠它认出已经开着的实例）、xdg-open 与 mimeinfo.cache（desktop-file-utils）；
# xdotool 点免责声明的「同意」
apt-get install -y -qq /dist/MeowX-*-linux-*.deb xvfb imagemagick procps libgl1-mesa-dri fonts-noto-cjk \
  dbus xdg-utils desktop-file-utils xdotool >/dev/null
stat -c "%U:%G %A %n" /usr/share/meowx/MeowXCore | tee "$OUT/$TAG-core.txt"
stat -c "%U:%A" /usr/share/meowx/MeowXCore | grep -q "^root:-rws" || fail "内核没有 root setuid"
# libdartjni.so：path_provider_android 依赖的 jni 包随所有平台编进来、只在 Android 上加载，它要的 libjvm 不用管
missing=$(find /usr/share/meowx -type f \( -name "*.so*" -o -name MeowX \) ! -name libdartjni.so \
  -exec env LD_LIBRARY_PATH=/usr/share/meowx/lib ldd {} \; 2>/dev/null | grep "not found" || true)
[[ -z "$missing" ]] || fail "缺库：$missing"

xvfb-run -a -s "-screen 0 1440x900x24" dbus-run-session -- bash "$0" "$TAG" --display
