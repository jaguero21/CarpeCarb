"""App Store creative assets (iOS 27): product page header and search results.

usage: creative.py <raw-phone-dir> backgrounds/header.png backgrounds/search.png \
         ../../screenshots/creative

Sizes and art-safe areas are Apple's (creative assets specifications and the
App Store Photoshop templates):
  header  3840 x 1646 (21:9), safe area x 1097-2743, y 493-1154
  search  3840 x 2560 (3:2),  safe area x 836-3004,  y 765-1795
Images are RGB with no alpha, as required.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

INK = (42, 37, 32)
GREEN = (77, 107, 71)
FONT = '/System/Library/Fonts/SFNS.ttf'


def bold(size):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name('Bold')
    except Exception:
        pass
    return f


def cover(bg, w, h):
    s = max(w / bg.width, h / bg.height)
    r = bg.resize((round(bg.width * s), round(bg.height * s)), Image.LANCZOS)
    l, t = (r.width - w) // 2, (r.height - h) // 2
    return r.crop((l, t, l + w, t + h)).filter(ImageFilter.GaussianBlur(radius=w / 260))


def panel(capture, box, height, radius=56):
    """A piece of the app, cut from a capture, as a rounded floating card."""
    crop = capture.crop(box).convert('RGB')
    w = round(crop.width * height / crop.height)
    crop = crop.resize((w, height), Image.LANCZOS)
    mask = Image.new('L', crop.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, height - 1), radius=radius, fill=255)
    return crop, mask


def place(canvas, piece, xy, shadow_blur=46):
    crop, mask = piece
    x, y = xy
    shadow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (x, y + 24, x + crop.width, y + crop.height + 24), radius=56, fill=(60, 45, 30, 60))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(shadow_blur)))
    canvas.paste(crop, (x, y), mask)
    return canvas


def headline(canvas, lines, size, box):
    """Two centred lines (ink, then green) filling `box` = (x0, y0, x1, y1)."""
    draw = ImageDraw.Draw(canvas)
    x0, y0, x1, y1 = box
    while True:
        f = bold(size)
        widths = [draw.textlength(t, font=f) for t in lines]
        if max(widths) <= (x1 - x0) or size < 40:
            break
        size -= 4
    line_h = round(size * 1.16)
    asc, desc = f.getmetrics()
    block = line_h * (len(lines) - 1) + asc + desc
    y = y0 + ((y1 - y0) - block) // 2
    for text, color, tw in zip(lines, (INK, GREEN), widths):
        draw.text((x0 + ((x1 - x0) - tw) / 2, y), text, font=f, fill=color)
        y += line_h
    return canvas


def main():
    raw, header_bg, search_bg, out = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
    out.mkdir(parents=True, exist_ok=True)
    home = Image.open(raw / '1_home.png')
    today = Image.open(raw / '2_today.png')
    # Today's total and the macro strip, on the app's cream background.
    total_box = (40, 380, 1280, 1390)
    # Dinner, Snack and Lunch, each with its total and a USDA-labelled row.
    meals_box = (40, 950, 1280, 2060)

    # Product page header: the brand line in the safe area; real app cards
    # either side, outside it, where a narrow device may crop them away.
    w, h = 3840, 1646
    c = cover(Image.open(header_bg).convert('RGB'), w, h).convert('RGBA')
    c = headline(c, ('Stop guessing.', 'Start knowing.'), 230, (1097, 493, 2743, 1154))
    ph = 700
    left = panel(home, total_box, ph)
    right = panel(today, meals_box, ph)
    c = place(c, left, (1097 - 110 - left[0].width, (h - ph) // 2 - 12))
    c = place(c, right, (2743 + 110, (h - ph) // 2 - 12))
    c.convert('RGB').save(out / 'product_page_header_3840x1646.png', optimize=True)

    # Search results: say what it does, and show it. Headline and both app
    # cards inside the safe area; the App Store lays its own text over the rest.
    w, h = 3840, 2560
    c = cover(Image.open(search_bg).convert('RGB'), w, h).convert('RGBA')
    c = headline(c, ('Type what you ate.', 'Get the carbs.'), 156, (836, 765, 3004, 1125))
    ph = 640
    a = panel(home, total_box, ph)
    b = panel(today, meals_box, ph)
    gap = 70
    total_w = a[0].width + gap + b[0].width
    x = (w - total_w) // 2
    y = 1145
    c = place(c, a, (x, y))
    c = place(c, b, (x + a[0].width + gap, y))
    c.convert('RGB').save(out / 'search_results_3840x2560.png', optimize=True)
    print('wrote', sorted(p.name for p in out.iterdir()))


if __name__ == '__main__':
    main()
