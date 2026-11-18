"""MeowX「X」图标（四个 90° 的 ^ 角尖对中心，中间留出等宽的 X；用户给的 meowx_caret_x_smaller.svg）按原几何重画。
SVG 里一格 168×168（圆角 40），以格心为原点：^ 的三个点 (-36,-51) → (0,-15) → (36,-51)，线宽 13、圆头圆角，转 0/90/180/270°。
三款：duo 双色（奶白底、玫红 / 樱粉交替）、ink 墨底（墨色底、全玫红）、gradient 渐变（樱粉 → 玫红对角渐变底、奶白线）。"""
import math
from PIL import Image, ImageDraw

CREAM, ROSE, SAKURA, INK = (0xF7, 0xF1, 0xEA), (0xC9, 0x51, 0x6F), (0xF6, 0xB9, 0xCC), (0x2E, 0x29, 0x33)
VARIANTS = {
    "duo": dict(bg=CREAM, strokes=[ROSE, SAKURA, ROSE, SAKURA]),
    "ink": dict(bg=INK, strokes=[ROSE] * 4),
    "gradient": dict(bg=("grad", SAKURA, ROSE), strokes=[CREAM] * 4),
}
TILE = 168.0
CARET = [(-36, -51), (0, -15), (36, -51)]
WIDTH = 13.0


def background(variant, side):
    bg = VARIANTS[variant]["bg"]
    if bg[0] != "grad":
        return Image.new("RGBA", (side, side), bg + (255,))
    _, a, b = bg
    # SVG 的 x1=0 y1=0 x2=1 y2=1（按包围盒）：沿主对角线，t = (x + y) / (2 · side)
    im = Image.new("RGBA", (side, side))
    px = im.load()
    for y in range(side):
        for x in range(side):
            t = (x + y) / (2 * (side - 1))
            px[x, y] = tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)) + (255,)
    return im


def carets(variant, side, unit, ss=4):
    """透明底上画四个 ^：unit = 每个 SVG 单位多少像素，图心 = 格心。ss 倍超采样后缩小抗锯齿。"""
    big = side * ss
    im = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = big / 2
    u = unit * ss
    w = WIDTH * u
    for k, color in enumerate(VARIANTS[variant]["strokes"]):
        ang = math.radians(90 * k)
        pts = []
        for x, y in CARET:
            rx, ry = x * math.cos(ang) - y * math.sin(ang), x * math.sin(ang) + y * math.cos(ang)
            pts.append((c + rx * u, c + ry * u))
        d.line(pts, fill=color + (255,), width=round(w), joint="curve")
        for p in (pts[0], pts[-1]):  # 圆头
            d.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=color + (255,))
    return im.resize((side, side), Image.LANCZOS)


def full(variant, side=1024):
    """满幅正方形（iOS 图标源图：系统自己套圆角遮罩）：一格 168 铺满。"""
    im = background(variant, side)
    im.alpha_composite(carets(variant, side, side / TILE))
    return im.convert("RGB")


def rounded_preview(variant, side=256, radius_ratio=40 / 168):
    """设置页的小预览：圆角照设计稿（168 里圆角 40）画进图里。"""
    im = full(variant, side).convert("RGBA")
    mask = Image.new("L", (side * 4, side * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, side * 4 - 1, side * 4 - 1], radius=side * 4 * radius_ratio, fill=255)
    im.putalpha(mask.resize((side, side), Image.LANCZOS))
    return im


if __name__ == "__main__":
    import sys
    out = sys.argv[1]
    sheet = Image.new("RGBA", (3 * 280, 280), (255, 255, 255, 255))
    for i, v in enumerate(VARIANTS):
        full(v).save(f"{out}/icon-x-{v}.png")
        sheet.alpha_composite(rounded_preview(v, 256), (12 + i * 280, 12))
    sheet.save(f"{out}/x-icons-preview.png")
    print("ok")
