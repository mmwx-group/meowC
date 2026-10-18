#!/usr/bin/env python3
# 从 design/brand/ 的源图生成 Android / Windows 全部品牌资源（需要 Pillow）。与 iOS / macOS 端同一套源图。
#   icon-art-light.png  亮色主题图标：白发猫娘（深色底的满幅正方形画，不带圆角；2026-10 换的新稿）
#   icon-art-dark.png   暗色主题图标：黑发猫娘（同一深色底的满幅正方形画）
#   glyph-solid.png     实心头像剪影成品（左半浅底黑图、右半深底白图，同一个形；取左半的黑色部分）
#                       → Android 通知 / 磁贴 / 快捷方式 / 主题图标单色层、Windows 托盘运行态。与 iOS 控制中心、macOS 菜单栏同一张
#   glyph-mono.png      早先的半身剪影，不再用，留作参考
#   icon-m-dark.png / icon-m-light.png  可选 App 图标：黑底白 M 猫脸 / 奶白底黑 M 猫脸（平涂底色的满幅正方形）→ 只 Android
# 用法：python3 scripts/make-brand-assets.py
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "design/brand")
RES = os.path.join(ROOT, "android/app/src/main/res")
IMAGES = os.path.join(ROOT, "assets/images")
LIGHT_BG = (23, 24, 31)      # 两张新画同一深色底
DARK_BG = (23, 24, 31)
DENSITY = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

def out(path):
    os.makedirs(os.path.dirname(path), exist_ok=True); return path

def full_art(path, bg, side=1024):
    # 带圆角的完整方形画 → 满幅正方形：圆角外（透明或纯黑）补成画的底色，裁到包围盒的内接正方形（水平居中、竖直贴顶）
    im = Image.open(path).convert("RGBA")
    a = im.split()[3]
    if a.getextrema()[0] == 255 and im.width == im.height:
        # 源图本身就是满幅正方形（没有圆角留白）：原样缩放，不裁不补——走下面的「非黑包围盒 + 四角填充」会把深色底当成
        # 圆角外的黑边处理掉。判据只看顶边同色（带圆角留白的旧式源图，顶角是留白、顶边中点是画；左右和底边不能算，
        # 头发衣服本来就画到边上）。与 MeowX 仓库 make-brand-assets.py 的 full_art 同一做法。
        rgb = im.convert("RGB"); w = rgb.width
        top = [rgb.getpixel(xy) for xy in ((0, 0), (w // 4, 0), (w // 2, 0), (w * 3 // 4, 0), (w - 1, 0))]
        if all(max(abs(c - e) for c, e in zip(p, top[0])) < 24 for p in top):
            return rgb.resize((side, side), Image.LANCZOS).convert("RGBA")
    if a.getextrema()[0] < 255:
        box = a.point(lambda v: 255 if v > 200 else 0).getbbox()
        flat = Image.new("RGBA", im.size, bg + (255,)); flat.alpha_composite(im); im = flat.convert("RGB")
    else:
        im = im.convert("RGB")
        box = im.convert("L").point(lambda v: 255 if v > 60 else 0).getbbox()
    l, t, r, b = box
    s = min(r - l, b - t); cx = (l + r) // 2
    crop = im.crop((cx - s // 2, t, cx - s // 2 + s, t + s))
    for xy in ((0, 0), (s - 1, 0), (0, s - 1), (s - 1, s - 1)):     # 四角容差填充成底色
        if sum(crop.getpixel(xy)) < 90:
            ImageDraw.floodfill(crop, xy, bg, thresh=70)
    return crop.resize((side, side), Image.LANCZOS).convert("RGBA")

def glyph_alpha():
    # 实心头像剪影 → alpha 掩码（黑 = 不透明），裁到内容包围盒。源图左半是浅底黑图，只取这一半
    src = Image.open(os.path.join(BRAND, "glyph-solid.png")).convert("L")
    lum = src.crop((0, 0, src.width // 2, src.height))
    alpha = lum.point(lambda v: 255 if v < 70 else (0 if v > 150 else int((150 - v) * 255 / 80)))
    return alpha.crop(alpha.point(lambda v: 255 if v > 128 else 0).getbbox())

def rounded(im, ratio):
    im = im.convert("RGBA"); w, h = im.size
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w - 1, h - 1), radius=int(w * ratio), fill=255)
    im.putalpha(m); return im

def circle(im):
    im = im.convert("RGBA"); w, h = im.size
    m = Image.new("L", (w, h), 0); ImageDraw.Draw(m).ellipse((0, 0, w - 1, h - 1), fill=255)
    im.putalpha(m); return im

def centered(im, side, fill, bg=(0, 0, 0, 0)):
    scale = side * fill / max(im.size)
    im = im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (side, side), bg)
    canvas.paste(im, ((side - im.width) // 2, (side - im.height) // 2), im)
    return canvas

def glyph_img(side, color, fill):
    a = GLYPH
    solid = Image.new("RGBA", a.size, color + (255,)); solid.putalpha(a)
    return centered(solid, side, fill)

def save_densities(make, name, folder, dp):
    for q, k in DENSITY.items():
        make(round(dp * k)).save(out(os.path.join(RES, f"{folder}-{q}", f"{name}.png")), optimize=True)

light_art = full_art(os.path.join(BRAND, "icon-art-light.png"), LIGHT_BG)
dark_art = full_art(os.path.join(BRAND, "icon-art-dark.png"), DARK_BG)
GLYPH = glyph_alpha()

# ---- Android 自适应图标：108dp 画布、可见区约 72dp。整幅画缩到画布的 70%（约 76dp）：可见区被画填满、猫耳留在安全区内；
#      画之外露出的一圈用同色背景层接上 ----
save_densities(lambda px: centered(light_art, px, 0.70), "ic_launcher_fg_light", "mipmap", 108)
save_densities(lambda px: centered(dark_art, px, 0.70), "ic_launcher_fg_dark", "mipmap", 108)
save_densities(lambda px: glyph_img(px, (255, 255, 255), 0.56), "ic_launcher_mono", "mipmap", 108)
for name, fg in (("light", "ic_launcher_fg_light"), ("dark", "ic_launcher_fg_dark")):
    for base in (f"ic_launcher_{name}", f"ic_launcher_round_{name}"):
        xml = base if name == "light" else base.replace("_dark", "")   # 深色版沿用 Bettbox 的 ic_launcher / ic_launcher_round 文件名
        with open(out(os.path.join(RES, "mipmap-anydpi-v26", f"{xml}.xml")), "w") as f:
            f.write('<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                    f'    <background android:drawable="@color/ic_launcher_bg_{name}" />\n'
                    f'    <foreground android:drawable="@mipmap/{fg}" />\n'
                    '    <monochrome android:drawable="@mipmap/ic_launcher_mono" />\n</adaptive-icon>\n')

# ---- 可选 App 图标（「我的 › 外观 › App 图标」，只 Android；Manifest 里 MainActivityMDark / MainActivityMLight 两个 alias 用）：
#      背景层 = 底色（四条边的中位数）；前景层 = 原图对底色做「颜色转透明」（叠回底色与原图逐像素相同，光晕保留成半透明），
#      按内容离中心最远的点缩进 108dp 画布中间 66dp 的安全圆——胡须在最外侧，圆形遮罩下不能被切；
#      单色层（Android 13 主题图标）= 与底色的差异（三个通道里最大的那个）：光晕 / 暗角那层淡色截掉、内容拉满，白色 ----
M_SAFE_DP = 33        # 安全圆半径（直径 66dp）

def edge_bg(im):
    w, h = im.size
    edge = [im.getpixel((x, y)) for x in range(w) for y in (0, h - 1)] + [im.getpixel((x, y)) for y in range(h) for x in (0, w - 1)]
    return tuple(sorted(p[i] for p in edge)[len(edge) // 2] for i in range(3))

def color_to_alpha(im, bg):
    # 每个像素取最小的 α 使 P = α·F + (1−α)·B 成立（GIMP 的 Color to Alpha），F 由此反推
    px_out = []
    for p in im.getdata():
        a = 0.0
        for c, b in zip(p, bg):
            if c != b:
                a = max(a, (c - b) / (255 - b) if c > b else (b - c) / b)
        if a <= 1 / 255:
            px_out.append(bg + (0,)); continue
        px_out.append(tuple(max(0, min(255, round((c - b) / a + b))) for c, b in zip(p, bg)) + (round(a * 255),))
    res = Image.new("RGBA", im.size); res.putdata(px_out); return res

def m_mono(im, bg):
    # 不用前景的 α：底色贴近 0 / 255 时一点点偏差就会被「颜色转透明」算成很高的 α（奶白底中间那圈更白的光晕 α≈0.75）。
    # 差异 < 64 的（光晕、暗角、压缩噪点）截掉，≥ 128 的（M / 耳朵 / 胡须）不透明
    a = Image.new("L", im.size)
    a.putdata([max(0, min(255, (max(abs(c - b) for c, b in zip(p, bg)) - 64) * 4)) for p in im.getdata()])
    return a

def placed(im, side, fill):
    # 同 centered()，但半透明图要用 alpha_composite 放上透明画布：centered() 的 paste(im, mask=im) 会把颜色和 α 都再乘一遍 α
    scale = side * fill / max(im.size)
    im = im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(im, ((side - im.width) // 2, (side - im.height) // 2))
    return canvas

def m_icon(name):
    im = Image.open(os.path.join(BRAND, f"icon-m-{name}.png")).convert("RGB").resize((1024, 1024), Image.LANCZOS)
    bg = edge_bg(im)
    fg = color_to_alpha(im, bg)
    mono = m_mono(im, bg)
    # 内容离画面中心最远的点：只算单色层里实的部分，光晕不算
    w, h = mono.size; mpx = mono.load(); r = 0.0
    for y in range(h):
        for x in range(w):
            if mpx[x, y] > 128:
                r = max(r, ((x + 0.5 - w / 2) ** 2 + (y + 0.5 - h / 2) ** 2) ** 0.5)
    fill = M_SAFE_DP / 108 * w / r     # placed() 按整幅图的边长缩放
    white = Image.new("RGBA", mono.size, (255, 255, 255, 255)); white.putalpha(mono)
    save_densities(lambda px: placed(fg, px, fill), f"ic_launcher_fg_m_{name}", "mipmap", 108)
    save_densities(lambda px: placed(white, px, fill), f"ic_launcher_mono_m_{name}", "mipmap", 108)
    with open(out(os.path.join(RES, "mipmap-anydpi-v26", f"ic_launcher_m_{name}.xml")), "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                f'    <background android:drawable="@color/ic_launcher_bg_m_{name}" />\n'
                f'    <foreground android:drawable="@mipmap/ic_launcher_fg_m_{name}" />\n'
                f'    <monochrome android:drawable="@mipmap/ic_launcher_mono_m_{name}" />\n</adaptive-icon>\n')
    # 设置页的预览缩略图（与 icon_light_256.png 同圆角同尺寸；「默认」那格直接用 icon_light_256.png）
    rounded(im, 0.22).resize((256, 256), Image.LANCZOS).save(out(os.path.join(IMAGES, f"app_icon_m_{name}_256.png")), optimize=True)
    print(f"m_{name}: bg #%02X%02X%02X, content r={r:.0f}px, fill {fill:.3f}" % bg)
    return bg

M_DARK_BG = m_icon("dark")
M_LIGHT_BG = m_icon("light")
with open(out(os.path.join(RES, "values", "ic_launcher_colors.xml")), "w") as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_bg_light">#%02X%02X%02X</color>\n    <color name="ic_launcher_bg_dark">#%02X%02X%02X</color>\n'
            '    <color name="ic_launcher_bg_m_dark">#%02X%02X%02X</color>\n    <color name="ic_launcher_bg_m_light">#%02X%02X%02X</color>\n</resources>\n'
            % (LIGHT_BG + DARK_BG + M_DARK_BG + M_LIGHT_BG))

# ---- Android 启动画面：288dp 画布、圆形遮罩内 192dp → 整幅画裁成圆 ----
def splash(art):
    return lambda px: centered(circle(art), px, 192 / 288)
save_densities(splash(light_art), "splash_text_light", "drawable", 288)
save_densities(splash(dark_art), "splash_text_dark", "drawable", 288)

# ---- Android 通知小图标 / 磁贴 / 快捷方式：单色剪影 ----
save_densities(lambda px: glyph_img(px, (255, 255, 255), 0.96), "ic", "drawable", 24)
glyph_img(550, (0, 0, 0), 0.84).save(out(os.path.join(RES, "drawable", "ic_shortcut_black.png")), optimize=True)
glyph_img(550, (255, 255, 255), 0.84).save(out(os.path.join(RES, "drawable", "ic_shortcut_white.png")), optimize=True)

# ---- Android TV 横幅 320×180 ----
banner = Image.new("RGBA", (640, 360), DARK_BG + (255,))
art = rounded(dark_art, 0.22).resize((300, 300), Image.LANCZOS); banner.paste(art, (170, 30), art)
banner.convert("RGB").resize((320, 180), Image.LANCZOS).save(out(os.path.join(RES, "drawable-xhdpi", "tv_banner.png")), optimize=True)

# ---- App 内 / 关于页 / 窗口标题图标：icon.png = 深色版、icon_light.png = 浅色版（沿用 Bettbox 的取名与 isDark 分支）----
rounded(dark_art, 0.22).save(out(os.path.join(IMAGES, "icon.png")), optimize=True)
rounded(light_art, 0.22).save(out(os.path.join(IMAGES, "icon_light.png")), optimize=True)
# App 内的头像（首页 / 侧栏 / 账户卡 / 关于页，最大 60dp）用 256 的小图：1024 的整图解码后 4MB 多，只为画 36–60dp。
# 这里先缩好而不是让 Flutter 按 cacheWidth 缩——引擎那一步是不带 mipmap 的双线性，缩 9 倍以上头发丝全是锯齿。
rounded(dark_art, 0.22).resize((256, 256), Image.LANCZOS).save(out(os.path.join(IMAGES, "icon_256.png")), optimize=True)
rounded(light_art, 0.22).resize((256, 256), Image.LANCZOS).save(out(os.path.join(IMAGES, "icon_light_256.png")), optimize=True)

# ---- Windows 可执行文件 / 安装包图标 ----
ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
rounded(light_art, 0.22).resize((256, 256), Image.LANCZOS).save(out(os.path.join(ROOT, "windows/runner/resources/app_icon.ico")), sizes=ICO_SIZES)

# ---- Windows 托盘（lib/common/utils.dart 的取名）：未运行 = 彩色圆角画（浅色任务栏用深色画 icon、深色任务栏用浅色画 icon_light，保证对比）；
#      运行中 = 单色剪影（浅色任务栏黑 icon_black、深色任务栏白 icon_white）----
TRAY_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)]
tray = {
    "icon": rounded(dark_art, 0.24).resize((256, 256), Image.LANCZOS),
    "icon_light": rounded(light_art, 0.24).resize((256, 256), Image.LANCZOS),
    "icon_black": glyph_img(256, (0, 0, 0), 0.98),
    "icon_white": glyph_img(256, (255, 255, 255), 0.98),
}
for name, im in tray.items():
    im.save(out(os.path.join(IMAGES, f"{name}.ico")), sizes=TRAY_SIZES)
    if name in ("icon_black", "icon_white"):   # 非 Windows 桌面端托盘用 png
        im.resize((550, 550), Image.LANCZOS).save(out(os.path.join(IMAGES, f"{name}.png")), optimize=True)
print("done")
