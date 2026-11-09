# Platen Reader

A free, open source (MPL-2.0), file-first ebook viewer for macOS, with iOS to follow. Double-click a book and you are reading in under a second, with no library, import step or account. The full product and technical spec is in `Platen Reader product and technical spec.md`; read it before making product decisions. Its "Decisions made" table is settled.

## Layout

- `PlatenCore/`: Swift package, platform-neutral (no AppKit, UIKit or WebKit). It holds the zip reader (Zip64, recovery scan), EPUB package parser, DRM detection, font de-obfuscation, path fix-ups, book identity and the per-book position store. Unit-tested.
- `PlatenReader/Sources/`: macOS app (AppKit, with SwiftUI for the overlay and Settings). It is a file-system-synchronised group, so new files need no project edits.
  - `BookDocument`: an `NSDocument`. The reader loads the file itself, in the background.
  - `ReaderViewController`: WKWebView, overlay, click zones, keys, the JS bridge and position saving.
  - `ReaderSchemeHandler`: serves `platen://reader/app/*` (the shell) and `platen://reader/book/*` (book files from memory). It also holds the CSP and the remote-load blocker.
  - `MainMenu`: the full command set. Actions go to the first responder.
- `PlatenReader/Web/`: `reader.html/js/css`, the shell that drives foliate-js. `foliate/` is vendored at a pinned commit (see `foliate/VENDORED.md`).
- `scripts/`: `make-fixtures.py` (synthetic robustness corpus → `Fixtures/generated/`), `run-debug.sh` (headless open + snapshots), `generate-xcodeproj.py`, `update-foliate.sh`.

## Build and test

```sh
swift test --package-path PlatenCore                       # core unit tests
xcodebuild -project PlatenReader.xcodeproj -scheme PlatenReader \
  -configuration Debug -derivedDataPath build/DerivedData build
python3 scripts/make-fixtures.py                           # regenerate corpus
scripts/run-debug.sh "$PWD/Fixtures/generated/novel.epub" "platen.next()"
# → log lines with open timings; PNG snapshots in build/snaps/
```

`run-debug.sh` relies on Debug-only hooks (`DebugHooks.swift`). `PLATEN_SNAPSHOT_DIR` writes web-view snapshots after the first render, and `PLATEN_STEPS` runs semicolon-separated JS commands (for example `platen.next()` or `platen.setSettings({...})`) one per second, taking a snapshot after each.

## Rules

- **The robustness corpus must stay green.** Every case in the spec's "Format support and robustness" table needs a fixture and a passing check. Add a fixture with every bug fix.
- Swift owns files, parsing and state; JS only drives foliate-js. Book bytes go down through the scheme handler, and events come back up through `post()` → `WKScriptMessageHandler`.
- Book scripts must never run, and remote loads must never happen. Both the CSP on the shell (inherited by foliate's blob iframes) and the WKContentRuleList enforce this. `Fixtures/generated/scripted.epub` and `remote-resource.epub` check them.
- Font obfuscation is undone in Swift (`FontDeobfuscator`), and `encryption.xml` is then hidden from foliate-js so it is not undone twice.
- No telemetry, no network and no permission prompts. Settings are global, and the only per-book data is position and bookmarks (`docs/per-book-data.md`).
- Comment liberally: explain what and why for a non-specialist. User-facing strings go in String Catalogs (development language en-GB).
- If you patch vendored foliate-js, record it in `PlatenReader/Web/foliate/VENDORED.md`.

## Status

M0 (spike) is done. Next is M1. See "Not yet done" in README.md.
