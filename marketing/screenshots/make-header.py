#!/usr/bin/env python3
"""The App Store product page's "Header and Search Results" picture
(iOS and iPadOS 27 and later): one 16:9 PNG, 5244 × 2950, flat RGB.

The App Store crops it to 21:9 for the header and to 3:2 in search results,
so everything that matters sits in the area both crops keep (the middle
4425 × 2247), with a margin; the edges are background only.

What it shows: on dark brown, the app icon, "Platen Reader" and one phrase,
beside an iPad reading Zoe and Zephy (page 15, light, ambient light on, the
controls showing). That page is captured from the app first:

  python3 capture.py --device ipad --scenes header-scenes --library <sample-library>

which saves build/raw/ipad/header.png (the scene is header-scenes/header).

Usage: python3 make-header.py
Writes build/header/header.png and two previews of the crops, with the
shared safe area outlined: preview-21x9.png and preview-3x2.png.
"""

import os
import subprocess
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
OUT = os.path.join(BUILD, "header")
SIZE = (5244, 2950)
# Laid out at half size in CSS pixels; WebKit draws at 2× on a Retina Mac.
CSS = (SIZE[0] // 2, SIZE[1] // 2)

PHRASE = "Easily read books,<br>or have Platen read to you."

def crops():
    """The 21:9 and 3:2 crops of the full picture, centred, in its pixels."""
    w, h = SIZE
    wide_h = round(w * 9 / 21)
    search_w = round(h * 3 / 2)
    wide = (0, (h - wide_h) // 2, w, (h + wide_h) // 2)
    search = ((w - search_w) // 2, 0, (w + search_w) // 2, h)
    safe = (search[0], wide[1], search[2], wide[3])
    return wide, search, safe


def page_html():
    # Fonts: the copies compose.py put in build/fonts (render.swift may read build/).
    w, h = CSS
    # The safe area, in CSS pixels, less a margin.
    _, _, safe = crops()
    left, top, right, bottom = (v / 2 for v in safe)
    margin = 70
    # The iPad, portrait, as tall as the safe area allows.
    screen_h = bottom - top - 2 * margin - 40
    screen_w = screen_h * 2064 / 2752
    bezel = screen_w * 0.03
    return f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: 'IBM Plex Sans'; font-weight: 600; src: url('../fonts/IBMPlexSans-SemiBold.ttf'); }}
@font-face {{ font-family: 'IBM Plex Sans'; font-weight: 400; src: url('../fonts/IBMPlexSans-Regular.ttf'); }}
html, body {{ margin: 0; width: {w}px; height: {h}px; overflow: hidden; }}
body {{
  /* Dark brown, as on the closing screenshot (palette.json 04), so the
     Honey icon stands out; a warm glow behind the iPad. */
  background: radial-gradient(ellipse 45% 70% at 68% 50%, #7a5326 0%, #4a3115 45%, #2a1c0c 100%);
  font-family: 'IBM Plex Sans', -apple-system, sans-serif; color: #fbefd3;
}}
.stage {{ position: absolute; left: {left + margin}px; top: {top + margin}px;
  width: {right - left - 2 * margin}px; height: {bottom - top - 2 * margin}px;
  display: flex; align-items: center; justify-content: space-between; }}
.words {{ display: flex; flex-direction: column; align-items: flex-start; }}
.icon {{ width: 240px; height: 240px; border-radius: 54px;
  box-shadow: 0 14px 44px rgba(0, 0, 0, 0.5); margin-bottom: 60px; }}
h1 {{ font-weight: 600; font-size: 168px; line-height: 1; letter-spacing: -3px; margin: 0 0 40px; }}
p {{ font-weight: 400; font-size: 76px; line-height: 1.18; margin: 0; color: #f4cf7e; }}
.device {{ padding: {bezel:.1f}px; background: #1d1a16; border-radius: {bezel * 2.2:.1f}px;
  box-shadow: 0 0 0 3px #3a332b, 0 40px 100px rgba(0, 0, 0, 0.55); flex: none; }}
.device img {{ display: block; width: {screen_w:.1f}px; height: {screen_h:.1f}px; border-radius: {bezel * 1.2:.1f}px; }}
</style></head><body><div class="stage">
<div class="words"><img class="icon" src="icon.png"><h1>Platen Reader</h1><p>{PHRASE}</p></div>
<div class="device"><img src="page.png"></div>
</div></body></html>
"""


def outline(picture, box, colour, width=14):
    draw = ImageDraw.Draw(picture)
    for i in range(width):
        draw.rectangle((box[0] + i, box[1] + i, box[2] - 1 - i, box[3] - 1 - i), outline=colour)


def main():
    raw = os.path.join(BUILD, "raw", "ipad", "header.png")
    icon = os.path.join(HERE, "..", "..", "PlatenReader iOS", "Sources", "Assets.xcassets",
                        "AppIcon.appiconset", "AppIcon-1024.png")
    if not os.path.exists(raw):
        sys.exit(f"{raw} is missing: run build.sh first")
    os.makedirs(OUT, exist_ok=True)
    Image.open(raw).convert("RGB").save(os.path.join(OUT, "page.png"))
    Image.open(icon).convert("RGB").save(os.path.join(OUT, "icon.png"))
    html_path = os.path.join(OUT, "header.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(page_html())

    snapshot = os.path.join(OUT, "snapshot.png")
    subprocess.run(["swift", os.path.join(HERE, "render.swift"), html_path, str(CSS[0]), str(CSS[1]), snapshot],
                   check=True)
    picture = Image.open(snapshot).convert("RGB")   # no alpha channel
    os.remove(snapshot)
    if picture.size != SIZE:
        picture = picture.resize(SIZE, Image.LANCZOS)
    out = os.path.join(OUT, "header.png")
    picture.save(out)

    # Previews: each crop, with the area both keep outlined.
    wide, search, safe = crops()
    for name, box in (("21x9", wide), ("3x2", search)):
        preview = picture.copy()
        outline(preview, safe, (200, 40, 40))
        preview = preview.crop(box)
        preview.thumbnail((1600, 1600))
        preview.save(os.path.join(OUT, f"preview-{name}.png"))
    print(out)


if __name__ == "__main__":
    main()
