"""可选 App 图标「X」三款（双色 / 墨底 / 渐变，设计稿 design/brand/icon-x.svg）→ Android 自适应图标 + 设置页预览。
用法：python3 scripts/make-x-icons.py（Pillow；本机没有 SVG 渲染器，几何在 scripts/x_icons.py 里按 SVG 重画，MeowX iOS 用同一份）。

自适应图标（108dp 画布、可见区约 72dp、安全圆直径 66dp）：
  - 背景层：满幅的底（奶白 / 墨色 / 对角渐变），位图，三款同一种写法；
  - 前景层：透明底上的四个 ^，设计稿一格 168 对应可见区 72dp（四个 ^ 最远约 29.5dp，在 33dp 安全圆里）；
  - 单色层（主题图标）：同一形状的白色剪影。
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import x_icons  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android/app/src/main/res")
DENSITY = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def out(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def save_densities(make, name, dp=108):
    for q, k in DENSITY.items():
        make(round(dp * k)).save(out(os.path.join(RES, f"mipmap-{q}", f"{name}.png")), optimize=True)


def fg(variant, side):
    return x_icons.carets(variant, side, side * (72 / 108) / x_icons.TILE)


def mono(variant, side):
    shape = fg(variant, side)
    white = Image.new("RGBA", shape.size, (255, 255, 255, 255))
    white.putalpha(shape.getchannel("A"))
    return white


for v in x_icons.VARIANTS:
    save_densities(lambda px, v=v: x_icons.background(v, px), f"ic_launcher_bg_x_{v}")
    save_densities(lambda px, v=v: fg(v, px), f"ic_launcher_fg_x_{v}")
    save_densities(lambda px, v=v: mono(v, px), f"ic_launcher_mono_x_{v}")
    with open(out(os.path.join(RES, "mipmap-anydpi-v26", f"ic_launcher_x_{v}.xml")), "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                f'    <background android:drawable="@mipmap/ic_launcher_bg_x_{v}" />\n'
                f'    <foreground android:drawable="@mipmap/ic_launcher_fg_x_{v}" />\n'
                f'    <monochrome android:drawable="@mipmap/ic_launcher_mono_x_{v}" />\n</adaptive-icon>\n')
    # 设置页 / 首页品牌栏的预览：256px、圆角画进图里（同 app_icon_m_*_256.png）
    x_icons.rounded_preview(v, 256).save(out(os.path.join(ROOT, "assets/images", f"app_icon_x_{v}_256.png")), optimize=True)
print("done")
