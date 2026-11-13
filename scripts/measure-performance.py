#!/usr/bin/env python3
"""Measures Platen Reader against the spec's performance targets.

Usage: scripts/measure-performance.py <book> [<second book>] [--runs N]

Build the Release app first:
    xcodebuild -project PlatenReader.xcodeproj -scheme PlatenReader \
      -configuration Release -derivedDataPath build/DerivedData \
      CODE_SIGNING_ALLOWED=NO build

It measures, on this Mac:
- cold launch plus open: from starting the app with the book to the first
  page being visible (the app logs "First page visible"), over several runs
- warm open: with the app already running, opening a second book
- memory: the app plus the WebKit processes it started, once the book is
  open (physical footprint, as Activity Monitor's Memory column shows)

Re-pagination after a resize is measured with the Debug build's "@resize:"
step (see CLAUDE.md), and page-turn smoothness needs Instruments.

Quit any running copy of Platen Reader first: a second copy hands its book
over to the first one and quits, which would spoil the timings.
"""
import os
import re
import statistics
import subprocess
import sys
import time
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/DerivedData/Build/Products/Release/Platen Reader.app")
BINARY = os.path.join(APP, "Contents/MacOS/Platen Reader")


def log_stream():
    """Follows the app's log; lines are read as they arrive."""
    return subprocess.Popen(
        ["/usr/bin/log", "stream", "--level", "info", "--style", "compact",
         "--predicate", 'subsystem == "Platen Reader"'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)


def wait_for(stream, pattern, timeout=20):
    """Returns (log timestamp, match) for the first line matching pattern."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = stream.stdout.readline()
        m = re.search(pattern, line)
        if m:
            stamp = datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f").timestamp()
            return stamp, m
    raise TimeoutError(pattern)


def webkit_processes():
    out = subprocess.run(["pgrep", "-f", "com.apple.WebKit"], capture_output=True, text=True).stdout
    return {int(p) for p in out.split()}


def footprint_mb(pids):
    """Physical footprint of these processes together, in MB."""
    total = 0.0
    for pid in pids:
        out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
        m = re.search(r"Footprint:\s*([\d.]+)\s*([KMG]B)", out)
        if m:
            value, unit = float(m.group(1)), m.group(2)
            total += value / 1024 if unit == "KB" else value * 1024 if unit == "GB" else value
    return total


def quit_platen():
    subprocess.run(["pkill", "-f", "Platen Reader.app/Contents/MacOS"], capture_output=True)
    time.sleep(1)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    runs = int(sys.argv[sys.argv.index("--runs") + 1]) if "--runs" in sys.argv else 5
    if not args:
        sys.exit(__doc__)
    if "--runs" in sys.argv:
        args = [a for a in args if a != str(runs)]
    book = os.path.abspath(args[0])
    second = os.path.abspath(args[1]) if len(args) > 1 else None
    if not os.path.exists(BINARY):
        sys.exit("Build the Release app first (see the top of this script).")

    size = os.path.getsize(book) / 1e6
    print(f"Book: {os.path.basename(book)} ({size:.1f} MB)")
    quit_platen()

    cold = []
    memory = None
    for run in range(runs):
        stream = log_stream()
        time.sleep(1)  # let the log stream attach
        before = webkit_processes()
        started = time.time()
        app = subprocess.Popen([BINARY, book, "-ApplePersistenceIgnoreState", "YES"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stamp, _ = wait_for(stream, r"First page visible after")
        cold.append((stamp - started) * 1000)
        if run == runs - 1:
            time.sleep(2)  # let the page settle before measuring memory
            memory = footprint_mb({app.pid} | (webkit_processes() - before))
            if second:
                # Warm open: the running app is asked to open another book,
                # as double-clicking it in the Finder would.
                subprocess.run(["open", "-a", APP, second])
                _, m = wait_for(stream, r"First page visible after (\d+) ms")
                warm = int(m.group(1))
        stream.terminate()
        quit_platen()

    print(f"Cold launch plus open: median {statistics.median(cold):.0f} ms "
          f"(runs: {', '.join(f'{c:.0f}' for c in cold)}); target under 1000 ms")
    if second:
        print(f"Warm open of {os.path.basename(second)}: {warm} ms; target under 400 ms")
    print(f"Memory with the book open (app plus WebKit): {memory:.0f} MB; target under 250 MB")


if __name__ == "__main__":
    main()
