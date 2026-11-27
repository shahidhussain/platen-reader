#!/usr/bin/env python3
"""Stage 1 of the App Store screenshots: the app itself, in the Simulator.

For each device (the largest iPhone and the 13-inch iPad) this script:

1. makes sure a simulator of our own exists ("Platen Screenshots iPhone",
   "Platen Screenshots iPad"), erases it so every run starts the same, boots
   it and sets a clean status bar (9:41, full battery and signal);
2. installs the Debug build and copies the sample books into the app's own
   Documents folder, as the folders in library.json (files on the Mac's own
   disk stall in the Simulator: see scripts/run-ios-debug.sh), plus the
   natural voice's pack (build/kokoro-pack, made by
   scripts/make-kokoro-pack.py), so read aloud never downloads anything;
3. for each scene in scenes/, launches the app set up for it, through the
   Debug-only hooks the app already has (PLATEN_FOLDER_PATH, PLATEN_OPEN_PATH,
   PLATEN_STEPS, PLATEN_KOKORO_PACK… see "PlatenReader iOS/Sources/DebugHooks.swift"
   and the new PLATEN_ADD_FAVOURITES), waits until it is ready and saves
   the whole screen with `xcrun simctl io … screenshot`.

Raw pictures go to build/raw/<device>/<scene>.png. Stage 2 (compose.swift)
puts them in their frames with the captions.

Usage:
  capture.py                      # every scene on every device
  capture.py --device iphone      # one device
  capture.py --only voice         # scenes whose folder name contains "voice"
  capture.py --library <folder>   # where the sample library is

The build is made by build.sh (or pass --app to use another .app).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BUILD = os.path.join(HERE, "build")
BUNDLE = "org.platenreader.PlatenReader"
APP = os.path.join(BUILD, "DerivedData/Build/Products/Debug-iphonesimulator/Platen Reader.app")
STEP_SECONDS = 1.5   # the app runs PLATEN_STEPS this far apart

# The devices: our own simulators, never the ones used day to day.
DEVICES = {
    "iphone": {"name": "Platen Screenshots iPhone",
               "type": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"},
    "ipad": {"name": "Platen Screenshots iPad",
             "type": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"},
}


# ---------------------------------------------------------------------------
# Small helpers

def sh(*args, check=True, env=None):
    """Runs a command and returns what it printed."""
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def simctl(*args, check=True, env=None):
    return sh("xcrun", "simctl", *args, check=check, env=env)


def read_scene(folder):
    """A scene.md: one `key: value` per line (# starts a comment)."""
    scene = {"id": os.path.basename(folder)}
    with open(os.path.join(folder, "scene.md"), encoding="utf-8") as f:
        for line in f:
            line = line.split(" #", 1)[0].strip()
            if ":" in line and not line.startswith("#"):
                key, value = line.split(":", 1)
                scene[key.strip()] = value.strip()
    return scene


def scenes(only=None, root=None):
    root = root or os.path.join(HERE, "scenes")
    found = [read_scene(os.path.join(root, name)) for name in sorted(os.listdir(root))
             if os.path.isfile(os.path.join(root, name, "scene.md"))]
    return [s for s in found if not only or only in s["id"]]


# ---------------------------------------------------------------------------
# The simulator

def latest_ios_runtime():
    runtimes = json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
    ios = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable")]
    # Only general runtimes ("…iOS-27-2"), not ones made for a single new
    # device ("…iOS-27-2-iPhone19-4"), which refuse other devices.
    ios = [r for r in ios if re.search(r"iOS-[\d-]+$", r["identifier"])]
    ios.sort(key=lambda r: [int(n) for n in r["version"].split(".")])
    return ios[-1]["identifier"]


def simulator(device):
    """The UDID of our own simulator for this device, made if missing."""
    spec = DEVICES[device]
    for runtime_devices in json.loads(simctl("list", "devices", "-j"))["devices"].values():
        for d in runtime_devices:
            if d["name"] == spec["name"] and d.get("isAvailable", True):
                return d["udid"]
    print(f"Making the simulator “{spec['name']}”…", flush=True)
    return simctl("create", spec["name"], spec["type"], latest_ios_runtime()).strip()


def clean_status_bar(udid):
    """9:41 on Tuesday 9 January 2007 (Apple's own; the iPad shows the
    date), full signal and battery, no carrier name."""
    simctl("status_bar", udid, "override", "--time",
           # In this Mac's own time zone (the Simulator's), so it reads 9:41; simctl
           # takes only ISO dates with milliseconds.
           datetime(2007, 1, 9, 9, 41).astimezone().isoformat(timespec="milliseconds"),
           "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
           "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
           "--batteryState", "discharging", "--batteryLevel", "100")


def fresh_boot(udid):
    """Erased (the same start every run), booted, with a clean status bar."""
    simctl("shutdown", udid, check=False)
    simctl("erase", udid)
    simctl("bootstatus", udid, "-b")
    time.sleep(5)   # let SpringBoard settle, or the date can come out wrong
    clean_status_bar(udid)
    # Light mode for the system parts (the reader's theme is set per scene).
    simctl("ui", udid, "appearance", "light", check=False)


def finish(udid):
    """Leaves the simulator as we found it: status bar cleared, shut down."""
    simctl("status_bar", udid, "clear", check=False)
    simctl("shutdown", udid, check=False)


# ---------------------------------------------------------------------------
# The app and its files

def full_screen_copy(app):
    """A copy of the build marked full screen (UIRequiresFullScreen), for
    screenshots only. iPadOS lets only a full-screen app turn itself
    sideways (the "@rotate" step), and draws no window corner on it; the
    app's pages look exactly the same. Re-signed ad hoc, as the Simulator
    needs."""
    copy = os.path.join(BUILD, "app", os.path.basename(app))
    shutil.rmtree(copy, ignore_errors=True)
    shutil.copytree(app, copy, symlinks=True)
    plist = os.path.join(copy, "Info.plist")
    sh("/usr/libexec/PlistBuddy", "-c", "Delete :UIRequiresFullScreen", plist, check=False)
    sh("/usr/libexec/PlistBuddy", "-c", "Add :UIRequiresFullScreen bool true", plist)
    sh("codesign", "--force", "--deep", "--sign", "-", copy)
    return copy


def install(udid, app, library):
    """Installs the app and copies the books and the voice pack into its
    container. Returns the container's path."""
    simctl("install", udid, full_screen_copy(app))
    container = simctl("get_app_container", udid, BUNDLE, "data").strip()
    documents = os.path.join(container, "Documents")
    with open(os.path.join(HERE, "library.json"), encoding="utf-8") as f:
        folders = {k: v for k, v in json.load(f).items() if not k.startswith("_")}
    for name, books in folders.items():
        os.makedirs(os.path.join(documents, name), exist_ok=True)
        for book in books:
            # "path", or ["path", "name to give the copy"], or with a third
            # item, the title to give a PDF copy (shown in the reader's bar).
            book = [book, os.path.basename(book)] if isinstance(book, str) else book
            source = os.path.join(library, book[0])
            if not os.path.exists(source):
                sys.exit(f"Missing from the sample library: {book[0]}")
            copy = os.path.join(documents, name, book[1])
            shutil.copy(source, copy)
            if len(book) > 2:
                subprocess.run(["swift", os.path.join(HERE, "set-pdf-title.swift"), copy, book[2]], check=True)
    pack = os.path.join(ROOT, "build", "kokoro-pack")
    if not os.path.isdir(pack):
        # The worktree may not have one; use the main checkout's.
        pack = os.path.join(os.path.dirname(library.rstrip("/")), "..", "build", "kokoro-pack")
    if os.path.isdir(pack):
        shutil.copytree(pack, os.path.join(container, "tmp", "kokoro-pack"), dirs_exist_ok=True)
    else:
        print("  (no build/kokoro-pack: read aloud will use the system voice)")
    return container, list(folders)


def launch(udid, container, extra_env, steps=()):
    """Starts the app afresh with these settings (as SIMCTL_CHILD_ variables,
    which simctl hands on to the app) and returns when it has started."""
    simctl("terminate", udid, BUNDLE, check=False)
    env = dict(os.environ)
    base = {
        # Settings, positions and lists in a folder of their own; settings
        # start from the defaults at every launch, the lists are kept.
        "PLATEN_TEST_HOME": os.path.join(container, "tmp", "screens-home"),
        "PLATEN_KOKORO_PACK": os.path.join(container, "tmp", "kokoro-pack"),
        "PLATEN_KEEP_CONTROLS": "1",
        "PLATEN_STEPS": ";".join(steps),
    }
    for key, value in {**base, **extra_env}.items():
        env["SIMCTL_CHILD_" + key] = value
    simctl("launch", udid, BUNDLE, env=env)


def wait_for_shot(container, name, timeout):
    """Waits for the app's own "@shot:<name>" picture: the sign that the
    steps before it have all run."""
    path = os.path.join(container, "tmp", "shots", name + ".png")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.5)
    return False


def screenshot(udid, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    clean_status_bar(udid)   # again: an app launch can reset its date
    time.sleep(1)
    simctl("io", udid, "screenshot", "--type=png", path)
    print(f"  saved {os.path.relpath(path, HERE)}", flush=True)


# ---------------------------------------------------------------------------
# The scenes

def capture_home(udid, container, folders, scene, out, device):
    """Home with the folders and favourites. Each folder is first opened
    once, as the reader would after choosing it, so its covers are read and
    its fan of covers can be made; then the app is started again on Home."""
    documents = os.path.join(container, "Documents")
    # Home lists folders newest first: connect them last to first.
    for name in reversed(folders):
        print(f"  connecting “{name}”…", flush=True)
        launch(udid, container, {"PLATEN_FOLDER_PATH": os.path.join(documents, name)})
        time.sleep(12)   # covers are read in the background
    favourites = [os.path.join(documents, p.strip()) for p in scene.get("favourites", "").split("|") if p.strip()]
    launch(udid, container, {"PLATEN_ADD_FAVOURITES": "|".join(favourites)})
    time.sleep(10)
    # Once more, so the fans are made from every cover now known.
    launch(udid, container, {})
    time.sleep(10)
    screenshot(udid, out)
    if device == "ipad":
        hide_window_corner(out)


def book_steps(scene):
    """The PLATEN_STEPS that set the reader up as the scene asks."""
    steps = [f"@theme:{scene.get('theme', 'light')}"]
    if scene.get("layout"):
        steps.append(f"@layout:{scene['layout']}")
    location = scene.get("location", "")
    if location.startswith("page "):
        # A PDF: turn to that page (counting from 1) one page at a time,
        # before turning sideways: Two Pages pairs pages starting from the
        # one on show when the phone is turned (PDFReaderViewController),
        # so a spread drawn across pages 22 and 23 is shown together.
        steps += ["@turn:next"] * (int(location.split()[1]) - 1)
    if scene.get("before") == "portrait":
        # A picture of the same page upright first ("@shot:before" is the
        # sign for the script to take it), for the card that shows the turn.
        steps += [f"@ambient:{scene.get('ambient', 'off')}", "@controls:hide",
                  "@wait", "@wait", "@shot:before", "@wait", "@wait"]
    if scene.get("orientation") == "landscape":
        steps += ["@rotate:landscape", "@wait"]
    if location.startswith("page "):
        pass
    elif location:
        # Foliate's own goToFraction: the reader's jumpToFraction would
        # offer "Back to 0%" under the page, as after any jump.
        steps.append(f"platen.view.goToFraction({float(location)})")
    steps.append(f"@ambient:{scene.get('ambient', 'off')}")
    if scene.get("readaloud") == "on":
        # Long enough for the highlight to move a few sentences down the
        # page, away from the controls at the top.
        steps += ["@voice:kokoro", "@readaloud"] + ["@wait"] * int(scene.get("listen", "6"))
    steps.append(f"@controls:{scene.get('controls', 'hide')}")
    steps += ["@wait", "@wait", "@shot:ready"]
    return steps


def capture_book(udid, container, scene, out, device):
    book = os.path.join(container, "Documents", scene["book"])
    steps = book_steps(scene)
    shutil.rmtree(os.path.join(container, "tmp", "shots"), ignore_errors=True)
    launch(udid, container, {"PLATEN_OPEN_PATH": book}, steps)
    if scene.get("before") == "portrait":
        before = out.replace(".png", "-before.png")
        if wait_for_shot(container, "before", 30 + STEP_SECONDS * len(steps)):
            screenshot(udid, before)
            if device == "ipad":
                hide_window_corner(before)
        else:
            print(f"  {scene['id']}: no upright picture (the steps did not get that far)")
    if not wait_for_shot(container, "ready", 30 + STEP_SECONDS * len(steps)):
        print(f"  {scene['id']}: the steps did not finish; screenshot taken anyway")
    screenshot(udid, out)
    if scene.get("orientation") == "landscape":
        upright(out)
    if device == "ipad":
        hide_window_corner(out)


def hide_window_corner(path):
    """iPadOS draws a small resize handle in an app window's bottom-right
    corner (windowed apps, even with UIRequiresFullScreen in the Simulator).
    It is not part of Platen, and Apple's own App Store pictures leave it
    out, so it is covered with the colour just beside it."""
    from PIL import Image, ImageDraw
    picture = Image.open(path).convert("RGB")
    w, h = picture.size
    size = 70   # the handle sits within about 60 pixels of the corner
    beside = picture.getpixel((w - size - 10, h - size // 2))
    ImageDraw.Draw(picture).rectangle((w - size, h - size, w, h), fill=beside)
    picture.save(path)


def upright(path):
    """A landscape scene, saved the right way up. The iPad's screenshot
    comes in the device's own portrait framing with the app turned on its
    side (top of the app at the right); the iPhone's is already upright."""
    from PIL import Image   # Pillow, as scripts/ios-matrix.py uses
    picture = Image.open(path)
    if picture.height > picture.width:
        picture.rotate(90, expand=True).save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", choices=list(DEVICES), action="append")
    parser.add_argument("--only")
    parser.add_argument("--scenes", help="a folder of scenes other than scenes/ (header-scenes/ for make-header.py)")
    parser.add_argument("--library", default=os.environ.get(
        "PLATEN_SAMPLE_LIBRARY", os.path.join(HERE, "..", "sample-library")))
    parser.add_argument("--app", default=APP)
    args = parser.parse_args()
    library = os.path.abspath(args.library)
    if not os.path.isdir(library):
        sys.exit(f"No sample library at {library} (pass --library)")
    if not os.path.isdir(args.app):
        sys.exit(f"No build at {args.app} (run build.sh)")

    for device in args.device or list(DEVICES):
        udid = simulator(device)
        print(f"{DEVICES[device]['name']}: starting…", flush=True)
        fresh_boot(udid)
        try:
            container, folders = install(udid, args.app, library)
            for scene in scenes(args.only, args.scenes and os.path.abspath(args.scenes)):
                out = os.path.join(BUILD, "raw", device, scene["id"] + ".png")
                show = scene.get("show")
                print(f" {scene['id']} ({show})", flush=True)
                if show == "home":
                    capture_home(udid, container, folders, scene, out, device)
                elif show == "book":
                    capture_book(udid, container, scene, out, device)
        finally:
            finish(udid)


if __name__ == "__main__":
    main()
