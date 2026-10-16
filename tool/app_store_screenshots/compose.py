"""Composites simulator captures onto the brand background with a headline,
in the 1.0.3 App Store screenshot layout, at App Store Connect's sizes.

usage: compose.py <raw-dir> <bg-image> <kind: phone|ipad> <out-root>
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HEADLINES = {
    '1_home': ('Type what you ate.', 'Get the carbs.'),
    '2_today': ('Carbs by meal,', 'with every source.'),
    '3_details': ('Change the serving.', 'The carbs follow.'),
    '4_saved': ('Your saved foods,', 'one tap away.'),
    '5_goals': ('Set goals for', 'carbs and macros.'),
    '6_features': ('Works with Apple Health', 'and iCloud.'),
}
INK = (42, 37, 32)        # #2A2520
GREEN = (77, 107, 71)     # #4D6B47 sageDark
FRAME = (28, 26, 24)
FONT = '/System/Library/Fonts/SFNS.ttf'

# Layout as fractions of the canvas, measured from the 1.0.3 set.
LAYOUT = {
    # 'iphone-6.3' is the required iPhone size (Dynamic Island, medium display);
    # the others fill the optional large-display slots.
    'phone': dict(sizes={'iphone-6.3': (1206, 2622), 'iphone': (1320, 2868),
                         'iphone-6.5': (1284, 2778)},
                  font=0.086, top=0.066, gap=1.18, frame_x=0.108, frame_top=0.182,
                  bezel=0.0175, radius=0.115, max_text=0.90),
    'ipad': dict(sizes={'ipad': (2064, 2752), 'ipad-12.9-2ndgen': (2048, 2732)},
                 font=0.068, top=0.062, gap=1.18, frame_x=0.137, frame_top=0.205,
                 bezel=0.0115, radius=0.045, max_text=0.86,
                 # The whole day fits on an iPad screen, so screen 1 already shows it.
                 skip={'2_today'}),
}


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
    return r.crop((l, t, l + w, t + h)).filter(ImageFilter.GaussianBlur(radius=w / 220))


def rounded_mask(size, radius):
    m = Image.new('L', size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return m


def compose(capture, bg, w, h, L, lines):
    canvas = cover(bg, w, h).convert('RGBA')
    draw = ImageDraw.Draw(canvas)

    # Headline: two centred lines, shrunk to fit if one is long.
    size = round(L['font'] * w)
    while True:
        f = bold(size)
        widths = [draw.textlength(t, font=f) for t in lines]
        if max(widths) <= L['max_text'] * w or size < 40:
            break
        size -= 2
    y = round(L['top'] * h)
    for text, color, tw in zip(lines, (INK, GREEN), widths):
        draw.text(((w - tw) / 2, y), text, font=f, fill=color)
        y += round(size * L['gap'])

    # Device: the capture inside a dark rounded frame, with a soft shadow.
    fx = round(L['frame_x'] * w)
    outer_w = w - 2 * fx
    bezel = round(L['bezel'] * w)
    inner_w = outer_w - 2 * bezel
    inner_h = round(inner_w * capture.height / capture.width)
    outer_h = inner_h + 2 * bezel
    fy = round(L['frame_top'] * h)
    radius = round(L['radius'] * outer_w)

    shadow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (fx, fy + bezel, fx + outer_w, fy + outer_h + bezel), radius=radius, fill=(40, 30, 20, 70))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(radius=w / 45)))

    frame = Image.new('RGBA', (outer_w, outer_h), FRAME + (255,))
    canvas.paste(frame, (fx, fy), rounded_mask((outer_w, outer_h), radius))
    screen = capture.convert('RGB').resize((inner_w, inner_h), Image.LANCZOS)
    canvas.paste(screen, (fx + bezel, fy + bezel), rounded_mask((inner_w, inner_h), max(radius - bezel, 0)))
    return canvas.convert('RGB')


def main():
    raw, bg_path, kind, out_root = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
    L = LAYOUT[kind]
    bg = Image.open(bg_path).convert('RGB')
    for name, lines in HEADLINES.items():
        if name in L.get('skip', ()):
            continue
        src = raw / f'{name}.png'
        if not src.exists():
            print('missing', src)
            continue
        capture = Image.open(src)
        for folder, (w, h) in L['sizes'].items():
            out = out_root / folder
            out.mkdir(parents=True, exist_ok=True)
            compose(capture, bg, w, h, L, lines).save(out / f'{name}.png', optimize=True)
            print('wrote', out / f'{name}.png', (w, h))


if __name__ == '__main__':
    main()
