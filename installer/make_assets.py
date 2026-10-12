"""Generates assets/app.ico and the installer wizard bitmaps (needs: pip install pillow)."""
from PIL import Image, ImageDraw, ImageFont
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

def icon_image(size=512):
    S = size
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # vertical red gradient, clipped to a rounded square
    grad = Image.new("RGBA", (S, S))
    top, bot = (248, 80, 80), (185, 28, 28)
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        gd.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([S * 0.04, S * 0.04, S * 0.96, S * 0.96], radius=S * 0.22, fill=255)
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)
    w = (255, 255, 255, 255)
    # down arrow: stem + head, then a tray line
    d.rectangle([S * 0.43, S * 0.20, S * 0.57, S * 0.52], fill=w)
    d.polygon([(S * 0.26, S * 0.50), (S * 0.74, S * 0.50), (S * 0.50, S * 0.76)], fill=w)
    d.rounded_rectangle([S * 0.24, S * 0.80, S * 0.76, S * 0.87], radius=S * 0.035, fill=w)
    return img

def font(size, bold=True):
    for name in ("DejaVuSans-Bold.ttf", "DejaVuSans.ttf", "LiberationSans-Bold.ttf"):
        for base in ("/usr/share/fonts/truetype/dejavu/", "/usr/share/fonts/truetype/liberation/"):
            p = base + name
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
    return ImageFont.load_default()

def gradient(w, h, top, bot):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return img

# --- app icon (multi-size .ico) ---
os.makedirs(os.path.join(ROOT, "assets"), exist_ok=True)
big = icon_image(512)
big.save(os.path.join(ROOT, "assets", "app.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
big.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, "assets", "app.png"))

# --- installer: welcome/finish side image 164x314 ---
side = gradient(164, 314, (31, 41, 55), (17, 24, 39))
side.paste(icon_image(512).resize((96, 96), Image.LANCZOS), (34, 40), icon_image(512).resize((96, 96), Image.LANCZOS))
d = ImageDraw.Draw(side)
d.text((82, 160), "YouTube", font=font(20), fill=(255, 255, 255), anchor="mm")
d.text((82, 186), "Downloader", font=font(20), fill=(255, 255, 255), anchor="mm")
d.text((82, 224), "MP3  &  MP4", font=font(13), fill=(248, 113, 113), anchor="mm")
d.text((82, 290), "queue  -  limits  -  tray", font=font(10, False), fill=(156, 163, 175), anchor="mm")
side.save(os.path.join(HERE, "wizard-side.bmp"))

# --- installer: header image 150x57 ---
head = gradient(150, 57, (31, 41, 55), (17, 24, 39))
ic = icon_image(512).resize((40, 40), Image.LANCZOS)
head.paste(ic, (100, 8), ic)
head.save(os.path.join(HERE, "wizard-header.bmp"))
print("assets written")
