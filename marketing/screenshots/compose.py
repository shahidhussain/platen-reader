#!/usr/bin/env python3
"""Stage 2 of the App Store screenshots: captions, frame and background.

For each scene, device and storefront spelling it writes a small HTML page
(the caption at the top, the raw screenshot from stage 1 in a device frame
below, on a background from palette.json), renders it with WebKit
(render.swift) and saves the result at exactly the size App Store Connect
asks for, without an alpha channel (it rejects transparency):

  build/final/<en-GB|en-US>/<iphone|iphone-6.3|ipad>/<scene>.png
  build/contact-sheet.html   every final picture side by side

Changing a caption means editing the scene's scene.md and running this
again; nothing is captured again.

Fonts: IBM Plex Sans, as on the website (shahidhussain.com uses it for its
headings), from fonts/ (github.com/IBM/plex, SIL Open Font License:
fonts/OFL.txt). Without them the captions fall back to the system font, and
the script says so.

Device frames: a drawn frame stands in until Apple's bezels (Apple Design
Resources) are put in bezels/ (see README.md).
"""

import html
import json
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageStat   # Pillow, as scripts/ios-matrix.py uses

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
PAGES = os.path.join(BUILD, "pages")

# App Store Connect's sizes (Help > Screenshot specifications): the 6.9-inch
# iPhone and the 13-inch iPad, portrait.
CANVAS = {"iphone": (1320, 2868), "ipad": (2064, 2752)}
# App Store Connect may instead ask for the 6.1/6.3-inch iPhone ("medium
# display": 1206 × 2622, as it did for 1.0.3). That is the 6.9-inch picture's
# shape within a pixel, so each iPhone picture is also saved scaled down.
SMALLER = {"iphone": ("iphone-6.3", (1206, 2622))}
# The storefront spellings: en-GB as written; en-US from the *_en_US fields.
LOCALES = {"en-GB": None, "en-US": "en_US"}
FONTS = {"IBMPlexSans-SemiBold.ttf": 600, "IBMPlexSans-Regular.ttf": 400}


def read_scene(folder):
    """A scene.md: one `key: value` per line (" #" starts a comment)."""
    scene = {"id": os.path.basename(folder)}
    with open(os.path.join(folder, "scene.md"), encoding="utf-8") as f:
        for line in f:
            line = line.split(" #", 1)[0].strip()
            if ":" in line and not line.startswith("#"):
                key, value = line.split(":", 1)
                scene[key.strip()] = value.strip()
    return scene


def field(scene, key, device, locale):
    """The most particular version of a field: for this device and spelling
    (subheading_ipad_en_US), this device, this spelling, or the plain one."""
    names = []
    if locale:
        names.append(f"{key}_{device}_{locale}")
    names.append(f"{key}_{device}")
    if locale:
        names.append(f"{key}_{locale}")
    names.append(key)
    return next((scene[n] for n in names if scene.get(n)), "")


def font_faces():
    """@font-face rules for the fonts present in fonts/ (copied beside the
    pages, which WebKit may read)."""
    rules, missing = [], []
    for name, weight in FONTS.items():
        source = os.path.join(HERE, "fonts", name)
        if os.path.exists(source):
            os.makedirs(os.path.join(BUILD, "fonts"), exist_ok=True)
            shutil.copy(source, os.path.join(BUILD, "fonts", name))
            rules.append(f"@font-face {{ font-family: 'IBM Plex Sans'; font-weight: {weight};"
                         f" src: url('../fonts/{name}'); }}")
        else:
            missing.append(name)
    if missing and not getattr(font_faces, "warned", False):
        font_faces.warned = True
        print(f"(fonts/ lacks {', '.join(missing)}: using the system font instead)")
    return "\n".join(rules)


def device_box(raw, width, height, device, landscape):
    """Where the framed screenshot goes and how big: the largest that fits
    in width × height. Returns the HTML for it."""
    picture = Image.open(raw)
    pw, ph = picture.size
    # The frame's edge, and the screen's own rounded corners, in proportion
    # to the screen's shorter side.
    short = min(pw, ph)
    bezel = short * (0.034 if device == "iphone" else 0.03)
    radius = short * (0.14 if device == "iphone" else 0.03)
    scale = min(width / (pw + 2 * bezel), height / (ph + 2 * bezel))
    w, h, b, r = pw * scale, ph * scale, bezel * scale, radius * scale
    path = os.path.relpath(raw, PAGES)
    return (f'<div class="device" style="padding:{b:.1f}px; border-radius:{r + b:.1f}px">'
            f'<img src="{html.escape(path)}" style="width:{w:.1f}px; height:{h:.1f}px;'
            f' border-radius:{r:.1f}px"></div>')


def page(scene, device, locale, palette):
    """The HTML for one screenshot."""
    W, H = CANVAS[device]
    colours = palette.get(scene["id"][:2], palette["01"])
    top = scene.get("background") or colours["top"]
    headline = html.escape(field(scene, "headline", device, locale))
    subheading = html.escape(field(scene, "subheading", device, locale))
    iphone = device == "iphone"
    margin = 90 if iphone else 150
    title_size, body_size = (112, 52) if iphone else (124, 58)
    raw = os.path.join(BUILD, "raw", device, scene["id"] + ".png")

    if scene.get("show") == "none":
        # The closing card: the icon, then the caption, centred.
        icon = os.path.relpath(os.path.join(BUILD, "icon.png"), PAGES)
        size = W * (0.3 if iphone else 0.22)
        body = (f'<main class="closing"><img class="icon" src="{icon}" style="width:{size:.0f}px;'
                f' height:{size:.0f}px; border-radius:{size * 0.2237:.0f}px">'
                f'<h1>{headline}</h1><p>{subheading}</p></main>')
    else:
        if not os.path.exists(raw):
            sys.exit(f"No capture for {scene['id']} on {device}: run capture.py first")
        header = 700 if iphone else 600
        landscape = scene.get("orientation") == "landscape"
        stage_w, stage_h = W - 2 * margin, H - header - margin
        before = raw.replace(".png", "-before.png")
        if os.path.exists(before):
            # The turn, told in two pictures: the page upright (behind, to
            # the left), then the spread sideways (in front, lower right).
            # Shares of the stage (width, height) for each, and how far the
            # sideways one rides up over the upright one.
            up, side, overlap = (((0.62, 0.70), (1.0, 0.56), 0.12) if iphone
                                 else ((0.55, 0.58), (0.9, 0.50), 0.10))
            upright = device_box(before, stage_w * up[0], stage_h * up[1], device, False)
            sideways = device_box(raw, stage_w * side[0], stage_h * side[1], device, True)
            box = (f'<div class="turn"><div class="upright">{upright}</div>'
                   f'<div class="sideways" style="margin-top:-{stage_h * overlap:.0f}px">{sideways}</div></div>')
        else:
            box = device_box(raw, stage_w, stage_h, device, landscape)
        body = (f'<header style="height:{header}px"><h1>{headline}</h1><p>{subheading}</p></header>'
                f'<section class="stage">{box}</section>')

    return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
{font_faces()}
* {{ margin: 0; box-sizing: border-box; }}
html, body {{ width: {W}px; height: {H}px; overflow: hidden; }}
body {{
  background: linear-gradient(180deg, {top}, {colours['bottom']});
  color: {colours['ink']};
  font-family: 'IBM Plex Sans', -apple-system, 'Helvetica Neue', sans-serif;
  display: flex; flex-direction: column; align-items: center;
  -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
}}
header {{
  display: flex; flex-direction: column; justify-content: center; align-items: center;
  padding: 0 {margin}px; text-align: center; gap: {body_size * 0.6:.0f}px;
}}
h1 {{ font-weight: 600; font-size: {title_size}px; line-height: 1.08; letter-spacing: -0.015em;
      text-wrap: balance; max-width: {W - 2 * margin}px; }}
p {{ font-weight: 400; font-size: {body_size}px; line-height: 1.32; opacity: 0.82;
     text-wrap: balance; max-width: {(W - 2 * margin) * 0.9:.0f}px; }}
.stage {{ flex: 1; display: flex; align-items: flex-start; justify-content: center; }}
.stage:has(.turn) {{ align-items: center; padding-bottom: {margin}px; }}
.device {{ background: {colours['frame']}; box-shadow: 0 {H * 0.012:.0f}px {H * 0.03:.0f}px rgba(40, 25, 5, 0.28); }}
.device img {{ display: block; }}
.turn {{ display: flex; flex-direction: column; width: {W - 2 * margin}px; }}
.upright {{ align-self: flex-start; margin-left: {(W - 2 * margin) * 0.04:.0f}px; }}
.sideways {{ align-self: flex-end; position: relative; }}
.closing {{ flex: 1; display: flex; flex-direction: column; justify-content: center; align-items: center;
            gap: {body_size * 0.9:.0f}px; padding: 0 {margin}px; text-align: center; }}
.closing h1 {{ font-size: {title_size * 1.15:.0f}px; }}
.closing .icon {{ box-shadow: 0 {H * 0.01:.0f}px {H * 0.03:.0f}px rgba(0, 0, 0, 0.35); margin-bottom: {body_size:.0f}px; }}
</style></head><body>{body}</body></html>
"""


def render(page_path, size, out, has_device=True):
    """WebKit's picture of the page, scaled to exactly `size`, flattened.
    A picture whose device frame came out empty is made again (twice at
    most), then the run stops, so an empty frame is never handed on."""
    os.makedirs(os.path.dirname(out), exist_ok=True)
    snapshot = out + ".snapshot.png"
    for attempt in range(3):
        subprocess.run(["swift", os.path.join(HERE, "render.swift"), page_path, str(size[0]), str(size[1]), snapshot],
                       check=True, capture_output=True)
        picture = Image.open(snapshot).convert("RGB")   # no alpha channel
        if picture.size != size:
            picture = picture.resize(size, Image.LANCZOS)
        os.remove(snapshot)
        if not has_device or not frame_is_empty(picture):
            picture.save(out)
            return
        print(f"  (empty frame in {os.path.basename(out)}, drawing it again)", flush=True)
    sys.exit(f"{out}: the screenshot inside the frame would not draw")


def frame_is_empty(picture):
    """True when the middle of the picture, where the screenshot sits, is
    one flat colour (the frame's, with nothing drawn in it)."""
    w, h = picture.size
    middle = picture.crop((int(w * 0.3), int(h * 0.45), int(w * 0.7), int(h * 0.75)))
    return max(ImageStat.Stat(middle).stddev) < 3


def contact_sheet(outputs):
    """build/contact-sheet.html: every final picture, by storefront and
    device, to look at the set as a whole."""
    rows = []
    for (locale, device), paths in outputs.items():
        pictures = "".join(f'<figure><img src="{os.path.relpath(p, BUILD)}"><figcaption>'
                           f'{html.escape(os.path.basename(p))}</figcaption></figure>' for p in paths)
        rows.append(f"<h2>{locale} · {device}</h2><div class='row'>{pictures}</div>")
    with open(os.path.join(BUILD, "contact-sheet.html"), "w", encoding="utf-8") as f:
        f.write("<!DOCTYPE html><meta charset='utf-8'><title>Platen Reader · App Store screenshots</title>"
                "<style>body{font:15px -apple-system,sans-serif;background:#eee;margin:24px}"
                ".row{display:flex;gap:16px;align-items:flex-start;margin-bottom:32px}"
                "figure{margin:0}img{height:520px;box-shadow:0 2px 10px #0003}"
                "figcaption{color:#666;margin-top:6px}</style>" + "".join(rows))


def main():
    with open(os.path.join(HERE, "palette.json"), encoding="utf-8") as f:
        palette = json.load(f)
    os.makedirs(PAGES, exist_ok=True)
    # The app icon, for the closing card.
    icon = os.path.join(HERE, "..", "..", "PlatenReader iOS", "Sources", "Assets.xcassets",
                        "AppIcon.appiconset", "AppIcon-1024.png")
    shutil.copy(icon, os.path.join(BUILD, "icon.png"))

    root = os.path.join(HERE, "scenes")
    # --only <text>: just the scenes whose folder name contains it (a scene
    # with no screenshot, such as 04, needs no captures).
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
    scenes = [read_scene(os.path.join(root, n)) for n in sorted(os.listdir(root))
              if os.path.isfile(os.path.join(root, n, "scene.md")) and only in n]
    outputs = {}
    for locale_name, locale in LOCALES.items():
        for device, size in CANVAS.items():
            for scene in scenes:
                page_path = os.path.join(PAGES, f"{locale_name}-{device}-{scene['id']}.html")
                with open(page_path, "w", encoding="utf-8") as f:
                    f.write(page(scene, device, locale, palette))
                out = os.path.join(BUILD, "final", locale_name, device, scene["id"] + ".png")
                render(page_path, size, out, has_device=scene.get("show") != "none")
                outputs.setdefault((locale_name, device), []).append(out)
                if device in SMALLER:
                    name, smaller = SMALLER[device]
                    small_out = os.path.join(BUILD, "final", locale_name, name, scene["id"] + ".png")
                    os.makedirs(os.path.dirname(small_out), exist_ok=True)
                    Image.open(out).resize(smaller, Image.LANCZOS).save(small_out)
                    outputs.setdefault((locale_name, name), []).append(small_out)
                print(f"  {os.path.relpath(out, HERE)}", flush=True)
    contact_sheet(outputs)
    print(f"Contact sheet: {os.path.relpath(os.path.join(BUILD, 'contact-sheet.html'), HERE)}")


if __name__ == "__main__":
    main()
