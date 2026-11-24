#!/usr/bin/env python3
"""Opens every book in samples/ (never committed: real-world books) in the
Mac app's Debug build, one at a time, and reports how each one went.

For each book: how long it took to open and show its first page; errors the
reader logged; the book's shape (sections, contents entries, direction,
fixed layout); whether the first page, a page three turns on and a page
half-way through have text (or a picture) on them; and snapshots of each,
kept in build/samples-pass/<book>/.

  python3 scripts/check-samples.py                 every book in samples/
  python3 scripts/check-samples.py --only dracula  books whose names contain it

Build the Debug app first (see CLAUDE.md). The report is printed and
written to build/samples-pass/report.txt. Nothing here is a pass or fail
by itself: it is for a person to read, alongside the snapshots.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SAMPLES = ROOT / "samples"
OUT = ROOT / "build" / "samples-pass"
SNAPS = ROOT / "build" / "snaps"
BOOKS = (".epub", ".mobi", ".azw3", ".azw", ".txt", ".pdf")

# What is on the page: how much text, and how many pictures (a page that is
# one picture has no text). Fixed-layout books show two documents at once.
# (One expression, no semicolons: run-debug.sh splits steps on them.)
PAGE = ("(c=>'{label} text:'+c.map(x=>x.doc.body?.innerText.trim().length||0).reduce((a,b)=>a+b,0)"
        "+' pictures:'+c.map(x=>x.doc.querySelectorAll('img,image,svg,video').length).reduce((a,b)=>a+b,0))"
        "(platen.view.renderer.getContents())")
SHAPE = ("'shape sections:'+platen.view.book.sections.length+' toc:'+(platen.view.book.toc?.length||0)"
         "+' dir:'+platen.view.book.dir+' fxl:'+platen.view.isFixedLayout+' lang:'+platen.view.book.metadata?.language")
STEPS = ";".join([
    SHAPE,
    PAGE.replace("{label}", "first"),
    "platen.next()", "platen.next()", "platen.next()",
    PAGE.replace("{label}", "turned"),
    "platen.view.goToFraction(0.5)",
    PAGE.replace("{label}", "middle"),
])


def run(book: Path) -> dict:
    """Opens one book and gathers its log lines."""
    shutil.rmtree(SNAPS, ignore_errors=True)
    env = dict(os.environ, PLATEN_TEST_HOME=tempfile.mkdtemp(prefix="platen-samples-"))
    steps = "" if book.suffix.lower() == ".pdf" else STEPS
    subprocess.run([str(ROOT / "scripts" / "run-debug.sh"), str(book), steps], env=env,
                   capture_output=True, text=True, timeout=180)
    log = (ROOT / "build" / "app.log").read_text(errors="replace")
    lines = []
    for line in log.splitlines():
        # Keep the message after "[Platen Reader:<category>] ", once each.
        m = re.search(r"\[Platen Reader:\w+\] (.*)", line)
        if m and m.group(1) not in lines:
            lines.append(m.group(1)[:300])
    # Keep the snapshots.
    dest = OUT / book.stem
    shutil.rmtree(dest, ignore_errors=True)
    if SNAPS.exists():
        shutil.copytree(SNAPS, dest)
    return {"book": book, "lines": lines}


def summarise(result: dict) -> str:
    lines = result["lines"]
    def find(prefix):
        return next((l for l in lines if l.startswith(prefix)), None)
    out = [f"== {result['book'].relative_to(SAMPLES)}"]
    for prefix in ("Read ", "First page visible", "Opening failed", "step result: shape",
                   "step result: first", "step result: turned", "step result: middle"):
        found = find(prefix)
        if found:
            out.append("   " + found.replace("step result: ", ""))
    problems = [l for l in lines if re.search(r"error|fail|warning|exception|could not|unreadable|repaired|rebuilt", l, re.I)
                and not l.startswith("step")]
    for p in problems[:8]:
        out.append("   ! " + p)
    if not find("First page visible") and not result["book"].suffix.lower() == ".pdf":
        out.append("   ! NO FIRST PAGE")
    return "\n".join(out)


def main():
    only = sys.argv[sys.argv.index("--only") + 1].lower() if "--only" in sys.argv else None
    books = sorted(p for p in SAMPLES.rglob("*") if p.suffix.lower() in BOOKS and (not only or only in p.name.lower()))
    OUT.mkdir(parents=True, exist_ok=True)
    report = []
    for book in books:
        text = summarise(run(book))
        print(text, flush=True)
        report.append(text)
    (OUT / "report.txt").write_text("\n".join(report) + "\n")
    print(f"\n{len(books)} books; report and snapshots in {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
