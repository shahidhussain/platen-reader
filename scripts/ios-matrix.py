#!/usr/bin/env python3
"""The iOS reader, checked across its settings in the Simulator.

Each book is opened once and taken through a list of states (theme,
ambient light, controls up or down, portrait or landscape, Two Pages,
Scroll, a theme switch, a turned page). In each state the app saves a
picture of its own window and logs its state ("@shot", "@report"; see
"PlatenReader iOS/Sources/DebugHooks.swift"), and for books the reader's
colour audit (platen.auditColours()). Simple rules are then checked against
the pictures and the reports: not a comparison with saved pictures, which
would break with every font or Simulator change, but properties that must
hold, such as "the band behind the controls is the glow's colour" or "the
room round a picture glows". Bugs found on a device become rules here.

Writes build/ios-matrix/: one folder of pictures per book, report.txt, and
sheet.png, a contact sheet of every picture with its failures marked, to be
looked at before pushing a change to the reader.

Usage:
  scripts/ios-matrix.py                 # the fixtures
  scripts/ios-matrix.py --samples       # and every EPUB, PDF and text file in samples/
  scripts/ios-matrix.py --only picture  # cases whose name contains "picture"
  scripts/ios-matrix.py --no-build      # use the last Debug build

Needs Pillow (pip install pillow). Takes a few minutes: each book is opened
once and its steps run 1.5 s apart. Exits with 1 if any rule fails.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime

from PIL import Image, ImageDraw, ImageStat

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "ios-matrix")
FIXTURES = os.path.join(ROOT, "Fixtures", "generated")
SIM = os.environ.get("PLATEN_SIM", "iPhone 18 Pro Max")
BUNDLE = "org.platenreader.PlatenReader"
APP = os.path.join(ROOT, "build/DerivedData/Build/Products/Debug-iphonesimulator/Platen Reader.app")
STEP_SECONDS = 1.5


# ---------------------------------------------------------------------------
# Cases: a book and its states. A state is a name, the steps that set it up,
# and the rules to check in it.

def state(name, steps=(), rules=(), settle=False):
    return {"name": name, "steps": list(steps) + (["@wait"] if settle else []), "rules": list(rules)}


def cases():
    return [
        {
            "name": "picture-book",
            "book": os.path.join(FIXTURES, "picture-book.epub"),
            "states": [
                # A square plate on a tall phone: room above and below it.
                state("dark-plate", ["@theme:dark", "@ambient:on", "@controls:hide"], ["picture_glows"], settle=True),
                state("dark-plate-controls", ["@controls:show"], ["bands_legible", "bands_match_glow:dark-plate"]),
                state("light-plate", ["@controls:hide", "@theme:light"], ["picture_glows"], settle=True),
                state("light-plate-controls", ["@controls:show"], ["bands_legible", "bands_match_glow:light-plate"]),
                state("plain-plate", ["@controls:hide", "@ambient:off"], ["picture_plain"], settle=True),
                # The contents page: dark blue Calibre links on Dark.
                state("dark-contents", ["@ambient:on", "@theme:dark", "@turn:next"], ["readable_text"], settle=True),
                state("light-contents", ["@theme:light"], ["readable_text"], settle=True),
                # The plate again, in landscape: room at the sides now.
                state("landscape-plate", ["@turn:prev", "@theme:dark", "@rotate:landscape"], ["picture_glows"],
                      settle=True),
                state("portrait-again", ["@rotate:portrait"], ["page_drawn"], settle=True),
            ],
        },
        {
            "name": "novel",
            "book": os.path.join(FIXTURES, "novel.epub"),
            "states": [
                state("dark", ["@theme:dark", "@ambient:on"], ["page_drawn", "readable_text", "edges_plain"],
                      settle=True),
                # A glow made from the dark page lingered as grey shading at
                # the sides after switching to Light (0.8.22).
                state("dark-to-light", ["@theme:light"], ["edges_plain"], settle=True),
                state("sepia-controls", ["@theme:sepia", "@controls:show"], ["bands_legible"], settle=True),
                state("scroll-dark-controls", ["@layout:scroll", "@theme:dark"], ["bands_legible", "page_drawn"],
                      settle=True),
                state("landscape-one", ["@layout:one", "@controls:hide", "@rotate:landscape"], ["page_drawn"],
                      settle=True),
                state("portrait-again", ["@rotate:portrait"], ["page_drawn"], settle=True),
            ],
        },
        {
            "name": "low-contrast",
            "book": os.path.join(FIXTURES, "low-contrast.epub"),
            "states": [
                state("dark", ["@theme:dark"], ["readable_text"], settle=True),
                state("light", ["@theme:light"], ["readable_text"], settle=True),
                state("black", ["@theme:black"], ["readable_text"], settle=True),
            ],
        },
        {
            "name": "cover-page",
            "book": os.path.join(FIXTURES, "cover-page.epub"),
            "states": [
                state("light", ["@theme:light", "@ambient:on", "@controls:hide"], ["page_drawn"], settle=True),
                state("dark-controls", ["@theme:dark", "@controls:show"], ["bands_legible"], settle=True),
            ],
        },
        {
            "name": "fixed-layout-wide",
            "book": os.path.join(FIXTURES, "fixed-layout-wide.epub"),
            "states": [
                state("dark", ["@theme:dark", "@ambient:on", "@controls:hide"], ["glow_fills"], settle=True),
                state("dark-controls", ["@controls:show"], ["bands_legible", "bands_match_glow:dark"], settle=True),
                state("light-next", ["@controls:hide", "@theme:light", "@turn:next"], ["glow_fills"], settle=True),
            ],
        },
        {
            "name": "square-pages",
            "book": os.path.join(FIXTURES, "square-pages.pdf"),
            "states": [
                state("portrait", ["@theme:light", "@ambient:on", "@layout:two"], ["page_drawn"], settle=True),
                # Square pages (picture books) were taken for spreads and
                # shown one at a time in landscape (0.8.22).
                state("landscape-two", ["@rotate:landscape"], ["two_pages:always"], settle=True),
                state("landscape-dark-controls", ["@theme:dark", "@controls:show"], ["bands_legible", "two_pages:always"],
                      settle=True),
                state("portrait-again", ["@controls:hide", "@rotate:portrait", "@layout:one"], ["page_drawn"],
                      settle=True),
            ],
        },
        {
            "name": "pictures",
            "book": os.path.join(FIXTURES, "pictures.pdf"),
            "states": [
                state("dark-controls", ["@theme:dark", "@ambient:on", "@controls:show"], ["bands_legible"],
                      settle=True),
                state("landscape", ["@controls:hide", "@layout:two", "@rotate:landscape"], ["page_drawn"],
                      settle=True),
                state("portrait-again", ["@rotate:portrait", "@layout:one"], ["page_drawn"], settle=True),
            ],
        },
    ]


def sample_cases():
    """Every EPUB, PDF and text file in samples/ (the reader's own books, never
    committed): a few pages in Dark and Light, with ambient light."""
    folder = os.path.join(ROOT, "samples")
    found = []
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        lower = name.lower()
        if not lower.endswith((".epub", ".pdf", ".txt")):
            continue
        pdf = lower.endswith(".pdf")
        text_rules = [] if pdf else ["readable_text"]
        states = [state("dark", ["@theme:dark", "@ambient:on", "@layout:one"], ["page_drawn"] + text_rules, settle=True)]
        for page in range(1, 4):
            states.append(state(f"dark-p{page + 1}", ["@turn:next"], ["page_drawn"] + text_rules, settle=True))
        states.append(state("dark-controls", ["@controls:show"], ["bands_legible"]))
        states.append(state("light", ["@controls:hide", "@theme:light"], ["page_drawn"] + text_rules, settle=True))
        found.append({"name": "sample-" + os.path.splitext(name)[0][:40], "book": os.path.join(folder, name),
                      "states": states, "pdf": pdf})
    return found


# ---------------------------------------------------------------------------
# Colours

def rgb(hex_colour):
    value = int(hex_colour.lstrip("#"), 16)
    return ((value >> 16) & 255, (value >> 8) & 255, value & 255)


def luminance(c):
    def linear(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])


def contrast(a, b):
    high, low = sorted([luminance(a), luminance(b)], reverse=True)
    return (high + 0.05) / (low + 0.05)


def distance(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def mean(image, box):
    """Mean colour of a box (in pixels) of the picture."""
    return tuple(ImageStat.Stat(image.crop(tuple(int(v) for v in box)).convert("RGB")).mean[:3])


# ---------------------------------------------------------------------------
# Rules: each takes the state's picture and report (and all the case's
# results, for rules that compare two states) and returns None if it holds,
# or what is wrong.

def rule_page_drawn(shot, report, results, arg):
    """Something is on screen: not a blank page (a failed render). Not
    for PDFs, which often have pages left blank on purpose."""
    if report.get("isPDF"):
        return None
    stddev = max(ImageStat.Stat(shot.convert("RGB")).stddev[:3])
    if stddev < 2:
        return f"the screen is one plain colour (spread {stddev:.1f})"


def rule_bands_legible(shot, report, results, arg):
    """The bands behind the controls leave their title and buttons readable."""
    if not report.get("controls"):
        return "the controls are not showing"
    text = (255, 255, 255) if report["dark"] else (0, 0, 0)
    for edge in ("topBand", "bottomBand"):
        band = rgb(report[edge] or report["theme"])
        if contrast(band, text) < 4.5:
            return f"{edge} {report[edge]} against the controls: contrast {contrast(band, text):.1f} (needs 4.5)"


def top_strip(shot, report):
    scale = shot.width / report["width"]
    return mean(shot, (0, 0, shot.width, 12 * scale))


def rule_bands_match_glow(shot, report, results, arg):
    """With ambient light, the top band is the colour the glow has there
    with the controls hidden (`arg`: that state): no fade from the glow to
    the page's colour."""
    if not report.get("ambient"):
        return None
    other = results.get(arg)
    if not other or other.get("shot") is None:
        return f"no state {arg} to compare with"
    hidden = top_strip(other["shot"], other["report"])
    shown = top_strip(shot, report)
    if distance(hidden, shown) > 45:
        return (f"top edge is {tuple(round(v) for v in shown)} with the controls, "
                f"{tuple(round(v) for v in hidden)} without: the band does not match the glow")


def room_round_picture(shot, report):
    """The room beside a picture-only page's picture (above it in portrait,
    to its left in landscape), as a box in pixels; None if there is little."""
    frame = report.get("pictureFrame")
    if not report.get("lonePicture") or not frame:
        return None
    scale = shot.width / report["width"]
    x, y, w, h = frame
    if y > 60:  # above, clear of the screen's top edge
        return (0, 30 * scale, shot.width, (y - 10) * scale)
    if x > 60:  # to the left
        return (30 * scale, 0, (x - 10) * scale, shot.height)
    return None


def rule_picture_glows(shot, report, results, arg):
    """With ambient light, the room round a picture-only page glows in the
    picture's colours rather than staying the page's plain colour."""
    if not report.get("lonePicture"):
        return "this is not a picture-only page"
    box = room_round_picture(shot, report)
    if box is None:
        return None
    seen = mean(shot, box)
    if distance(seen, rgb(report["theme"])) < 30:
        return f"the room round the picture is plain {tuple(round(v) for v in seen)}, the page's colour"


def rule_picture_plain(shot, report, results, arg):
    """Without ambient light, the room round a picture is the page's colour."""
    box = room_round_picture(shot, report)
    if box is None:
        return None
    seen = mean(shot, box)
    if distance(seen, rgb(report["theme"])) > 12:
        return f"the room round the picture is {tuple(round(v) for v in seen)}, not the page's colour"


def rule_edges_plain(shot, report, results, arg):
    """On a page of text, the glow at the screen's sides stays close to the
    page's colour (no shading left from another theme)."""
    scale = shot.width / report["width"]
    theme = rgb(report["theme"])
    for box in ((0, shot.height * 0.3, 10 * scale, shot.height * 0.7),
                (shot.width - 10 * scale, shot.height * 0.3, shot.width, shot.height * 0.7)):
        seen = mean(shot, box)
        if distance(seen, theme) > 30:
            return f"the side of the screen is {tuple(round(v) for v in seen)}, far from the page's {report['theme']}"


def rule_glow_fills(shot, report, results, arg):
    """With ambient light, a page set apart in the middle of the screen (a
    fixed-layout book's, wider than the phone) glows all round: the room
    above it is lit in the page's colours, not left the page's plain colour
    with smudges at the corners (Lory Dory, 0.8.25)."""
    if not report.get("ambient"):
        return None
    box = (shot.width * 0.2, shot.height * 0.1, shot.width * 0.8, shot.height * 0.16)
    seen = mean(shot, box)
    if distance(seen, rgb(report["theme"])) < 30:
        return f"the room above the page is plain {tuple(round(v) for v in seen)}, the page's colour"


def rule_two_pages(shot, report, results, arg):
    """Two Pages in landscape shows two pages, unless they are spreads
    (`arg` "always": these pages are not, whatever the app thinks)."""
    if not report.get("landscape"):
        return "not in landscape"
    if report.get("spreads") and arg != "always":
        return None
    if report.get("columns", 1) < 2:
        return f"{report.get('columns')} page on screen in landscape with Two Pages"


def rule_readable_text(shot, report, results, arg):
    """No text left too faint to read against the page (the colour audit)."""
    audit = report.get("audit")
    if audit is None:
        return "no colour audit came back"
    if audit.get("lowContrast"):
        return f"{audit['lowContrast']} faint: " + "; ".join(audit.get("examples", []))


RULES = {name[5:]: fn for name, fn in globals().items() if name.startswith("rule_")}


# ---------------------------------------------------------------------------
# Running a case in the Simulator

def sh(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def build():
    print("Building the iOS app…", flush=True)
    result = subprocess.run(
        ["xcodebuild", "-project", "PlatenReader.xcodeproj", "-scheme", "PlatenReader iOS",
         "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
         "-derivedDataPath", "build/DerivedData", "CODE_SIGNING_ALLOWED=NO", "build"],
        cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print("\n".join(l for l in result.stdout.splitlines() if "error:" in l) or result.stdout[-2000:])
        sys.exit(2)


def run_case(case):
    """Opens the case's book, runs its states and returns {state name:
    {"shot": Image, "report": dict}}."""
    steps = []
    for s in case["states"]:
        steps += s["steps"] + ["@report"]
        if not case.get("pdf") and not case["book"].endswith(".pdf"):
            steps.append("platen.auditColours()")
        steps.append(f"@shot:{s['name']}")
    subprocess.run(["xcrun", "simctl", "terminate", SIM, BUNDLE], capture_output=True)
    container = sh("xcrun", "simctl", "get_app_container", SIM, BUNDLE, "data").strip()
    documents = os.path.join(container, "Documents")
    shots = os.path.join(container, "tmp", "shots")
    os.makedirs(documents, exist_ok=True)
    shutil.rmtree(shots, ignore_errors=True)
    book = os.path.join(documents, os.path.basename(case["book"]))
    shutil.copy(case["book"], book)

    started = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    env = dict(os.environ,
               SIMCTL_CHILD_PLATEN_OPEN_PATH=book,
               SIMCTL_CHILD_PLATEN_STEPS=";".join(steps),
               SIMCTL_CHILD_PLATEN_KEEP_CONTROLS="1",
               SIMCTL_CHILD_PLATEN_TEST_HOME="1")
    subprocess.run(["xcrun", "simctl", "launch", SIM, BUNDLE], env=env, check=True, capture_output=True)

    # Wait for the last picture (the first page can take several seconds in
    # the Simulator before the steps start).
    expected = [s["name"] for s in case["states"]]
    deadline = time.time() + 25 + STEP_SECONDS * len(steps)
    while time.time() < deadline:
        if os.path.exists(os.path.join(shots, expected[-1] + ".png")):
            break
        time.sleep(1)
    time.sleep(0.5)
    subprocess.run(["xcrun", "simctl", "terminate", SIM, BUNDLE], capture_output=True)

    log = subprocess.run(["xcrun", "simctl", "spawn", SIM, "log", "show", "--start", started, "--info",
                          "--style", "compact", "--predicate", 'subsystem == "Platen Reader"'],
                         capture_output=True, text=True).stdout
    # One report, one audit (books) and one picture per state, in order;
    # matched by order, as a result can be logged a moment after the
    # picture that follows it.
    reports, audits, names = [], [], []
    for line in log.splitlines():
        if "] report: " in line:
            reports.append(json.loads(line.split("] report: ", 1)[1]))
        elif "] step result: " in line:
            try:
                audits.append(json.loads(line.split("] step result: ", 1)[1]))
            except json.JSONDecodeError:
                pass
        elif "] shot: " in line:
            names.append(line.split("] shot: ", 1)[1].strip())
    results = {}
    for index, name in enumerate(names):
        report = reports[index] if index < len(reports) else {}
        if index < len(audits):
            report["audit"] = audits[index]
        results[name] = {"report": report, "shot": None}

    folder = os.path.join(OUT, case["name"])
    os.makedirs(folder, exist_ok=True)
    for name in expected:
        path = os.path.join(shots, name + ".png")
        entry = results.setdefault(name, {"report": {}, "shot": None})
        if os.path.exists(path):
            shutil.copy(path, os.path.join(folder, name + ".png"))
            entry["shot"] = Image.open(path).convert("RGB")
    return results


def check(case, results):
    failures = []
    for s in case["states"]:
        entry = results.get(s["name"], {})
        entry["failures"] = []
        if entry.get("shot") is None or not entry.get("report"):
            entry["failures"].append("no picture or report (the steps did not finish)")
        else:
            for rule in s["rules"]:
                name, _, arg = rule.partition(":")
                problem = RULES[name](entry["shot"], entry["report"], results, arg)
                if problem:
                    entry["failures"].append(f"{name}: {problem}")
        failures += [f"{case['name']} / {s['name']}: {f}" for f in entry["failures"]]
    return failures


# ---------------------------------------------------------------------------
# The contact sheet: a row per book, a picture per state, failures in red.

def contact_sheet(all_cases, all_results, path):
    thumb_h = 300
    rows = []
    for case in all_cases:
        results = all_results.get(case["name"], {})
        cells = []
        for s in case["states"]:
            entry = results.get(s["name"], {})
            shot = entry.get("shot")
            if shot is None:
                image = Image.new("RGB", (138, thumb_h), (90, 90, 90))
            else:
                image = shot.copy()
                image.thumbnail((thumb_h * 2, thumb_h))
            failed = bool(entry.get("failures"))
            cell = Image.new("RGB", (max(image.width, 150) + 8, thumb_h + 8 + 30), (200, 30, 30) if failed else (235, 235, 235))
            cell.paste(image, (4, 4))
            ImageDraw.Draw(cell).text((4, thumb_h + 12), ("✗ " if failed else "") + s["name"],
                                      fill=(255, 255, 255) if failed else (20, 20, 20))
            cells.append(cell)
        width = sum(c.width for c in cells) + 6 * len(cells) + 10
        row = Image.new("RGB", (max(width, 400), thumb_h + 38 + 24), (250, 250, 250))
        ImageDraw.Draw(row).text((6, 4), case["name"], fill=(0, 0, 0))
        x = 6
        for c in cells:
            row.paste(c, (x, 20))
            x += c.width + 6
        rows.append(row)
    if not rows:
        return
    sheet = Image.new("RGB", (max(r.width for r in rows), sum(r.height for r in rows)), (250, 250, 250))
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--samples", action="store_true", help="also every EPUB, PDF and text file in samples/")
    parser.add_argument("--only", help="only cases whose name contains this")
    parser.add_argument("--no-build", action="store_true", help="use the last Debug build")
    args = parser.parse_args()

    chosen = cases() + (sample_cases() if args.samples else [])
    if args.only:
        chosen = [c for c in chosen if args.only in c["name"]]
    if not args.no_build:
        build()
    subprocess.run(["xcrun", "simctl", "bootstatus", SIM, "-b"], capture_output=True)
    subprocess.run(["xcrun", "simctl", "install", SIM, APP], check=True)
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)

    all_results, failures, lines = {}, [], []
    for case in chosen:
        print(f"{case['name']}: {len(case['states'])} states…", flush=True)
        results = run_case(case)
        all_results[case["name"]] = results
        found = check(case, results)
        failures += found
        for s in case["states"]:
            entry = results.get(s["name"], {})
            mark = "FAIL" if entry.get("failures") else "PASS"
            lines.append(f"{mark}  {case['name']} / {s['name']}")
            lines += [f"      {f}" for f in entry.get("failures", [])]
        print("\n".join("  " + f for f in found) or "  all passed", flush=True)

    with open(os.path.join(OUT, "report.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    contact_sheet(chosen, all_results, os.path.join(OUT, "sheet.png"))
    passed = sum(1 for l in lines if l.startswith("PASS"))
    print(f"\n{passed} passed, {len(failures)} failed. Pictures, report.txt and sheet.png in build/ios-matrix/")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
