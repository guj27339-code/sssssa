"""Генерация иконок PWA для Dark Side Car's.

Знак оригинальный: тёмная сфера с янтарным световым серпом справа —
отсылка одновременно к «тёмной стороне» в названии и к блику на
отполированном лаке. Логотип студии сюда не используется, владелец
может заменить иконки на свои.
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

BG = (14, 16, 18)
AMBER = (245, 166, 35)
WARM = (255, 214, 140)

SS = 4  # суперсэмплинг


def sphere(size, inset):
    """Сфера с боковым светом, вписанная в квадрат size с отступом inset (доля)."""
    S = size * SS
    pad = int(S * inset)
    d = S - 2 * pad
    r = d / 2.0
    cx = cy = pad + r

    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    dx = (xx - cx) / r
    dy = (yy - cy) / r
    rr = dx * dx + dy * dy
    inside = rr <= 1.0

    # нормаль полусферы
    dz = np.sqrt(np.clip(1.0 - rr, 0.0, 1.0))

    # источник света справа-сверху
    L = np.array([0.72, -0.45, 0.53], dtype=np.float32)
    L /= np.linalg.norm(L)
    lam = np.clip(dx * L[0] + dy * L[1] + dz * L[2], 0.0, 1.0)

    # мягкий терминатор: свет гаснет быстро, оставляя серп
    lit = np.power(lam, 2.6)

    # узкий зеркальный блик
    spec = np.power(np.clip(lam, 0.0, 1.0), 42.0)

    base = np.zeros((S, S, 3), dtype=np.float32)
    for i in range(3):
        # тёмная сторона чуть светлее фона, чтобы сфера читалась силуэтом
        dark = BG[i] + 10
        base[..., i] = dark + (AMBER[i] - dark) * lit + (WARM[i] - AMBER[i]) * spec * 0.9

    # ободок по краю с освещённой стороны
    edge = np.clip(1.0 - np.abs(np.sqrt(np.clip(rr, 0, 4)) - 0.985) / 0.02, 0, 1)
    rim = edge * np.power(np.clip(lam, 0, 1), 0.6)
    for i in range(3):
        base[..., i] = base[..., i] + (WARM[i] - base[..., i]) * rim * 0.75

    rgb = np.clip(base, 0, 255).astype(np.uint8)
    alpha = (inside * 255).astype(np.uint8)

    img = Image.fromarray(np.dstack([rgb, alpha]), "RGBA")
    return img.resize((size, size), Image.LANCZOS)


def plate(size, radius_ratio, inset):
    """Иконка целиком: подложка + сфера."""
    S = size * SS
    bg = Image.new("RGBA", (S, S), BG + (255,))

    if radius_ratio > 0:
        mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, S - 1, S - 1], radius=int(S * radius_ratio), fill=255
        )
        bg.putalpha(mask)

    bg = bg.resize((size, size), Image.LANCZOS)

    ball = sphere(size, inset)

    # тёплое свечение вокруг сферы
    glow = ball.filter(ImageFilter.GaussianBlur(size * 0.07))
    out = Image.alpha_composite(bg, Image.merge("RGBA", (*glow.split()[:3], glow.split()[3].point(lambda v: int(v * 0.45)))))
    out = Image.alpha_composite(out, ball)
    return out


# any-иконки: сфера занимает почти всё поле
for s in (192, 512):
    plate(s, 0.22, 0.10).save(f"icons/icon-{s}.png")

# maskable: содержимое внутри безопасной зоны 80%, подложка на всю площадь
for s in (192, 512):
    plate(s, 0.0, 0.22).save(f"icons/maskable-{s}.png")

# apple-touch-icon: iOS сам скругляет, поле без прозрачности
plate(180, 0.0, 0.12).convert("RGB").save("icons/apple-touch-icon.png")

# favicon
ico = plate(64, 0.18, 0.08)
ico.save("icons/favicon-64.png")
ico.resize((32, 32), Image.LANCZOS).save("icons/favicon.ico", sizes=[(32, 32), (16, 16)])

print("готово")
