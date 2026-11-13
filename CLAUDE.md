# Platen Reader

A free, open source (MPL-2.0), file-first ebook viewer for macOS, with iOS to follow. Double-click a book and you are reading in under a second, with no library, import step or account. The full product and technical spec is in `Platen Reader product and technical spec.md`; read it before making product decisions. Its "Decisions made" table is settled.

## Layout

- `PlatenCore/`: Swift package, platform-neutral (no AppKit, UIKit or WebKit). It holds the zip reader (Zip64, recovery scan), EPUB package parser, DRM detection, font de-obfuscation, path fix-ups, book identity and the per-book position store. Unit-tested.
- `PlatenReader/Shared/`: code used by both the Mac and iOS apps (scheme handler with CSP and remote-load blocker, `ReaderState`, the settings model, the String Catalog, the log). A synchronised folder in both app targets. Nothing here may import AppKit or UIKit; platform parts go in `+AppKit` / `+UIKit` files in each app.
- `Config/Shared.xcconfig`: the version, bundle ID and minimum OS versions, shared by both app targets.
- `PlatenReader/Sources/`: macOS app (AppKit, with SwiftUI for the overlay and Settings). It is a file-system-synchronised group, so new files need no project edits.
  - `BookDocument`: an `NSDocument`. The reader loads the file itself, in the background.
  - `ReaderViewController`: WKWebView, overlay, click zones, keys, the JS bridge and position saving.
  - `ReaderSchemeHandler`: serves `platen://reader/app/*` (the shell) and `platen://reader/book/*` (book files from memory). It also holds the CSP and the remote-load blocker.
  - `MainMenu`: the full command set. Actions go to the first responder.
- PDFs are shown by PDFKit, not the web shell: `PlatenCore/PDFIdentity` (identity), `Shared/PDFReaderModel` (outline, page bookmarks, search, position, feeding the same `ReaderState` and overlay), and a `PDFReaderViewController` in each app. Fixture: `Fixtures/generated/outline.pdf`.
- `PlatenReader iOS/`: the iOS and iPadOS app (target "PlatenReader iOS", same bundle ID): the document browser as the home screen, and a UIKit reader around the same web shell. M3 is planned phase by phase in `docs/m3-ios-plan.md`.
- `PlatenReader/Web/`: `reader.html/js/css`, the shell that drives foliate-js. `foliate/` is vendored at a pinned commit (see `foliate/VENDORED.md`).
- `design/icon/`: the app icon. `make-icons.py` draws it (SVG, in several background colours; Honey is the one in use), Quick Look renders it, and `mask-icon.swift` makes the corners transparent. The sizes live in `PlatenReader/Sources/Assets.xcassets/AppIcon.appiconset`.
- `scripts/`: `make-fixtures.py` (synthetic robustness corpus → `Fixtures/generated/`), `check-corpus.sh` (opens each fixture and checks the result), `run-debug.sh` (headless open + snapshots), `update-foliate.sh`. The Xcode project is maintained in Xcode; `PlatenReader/Sources` is a synchronised folder, so new files need no project edits.
- Reader features live in `reader.js` (opening, the `platen` commands) and `PlatenReader/Web/modules/` (one module per feature: layout, book fixes, input, page numbers, bookmarks, jumps, search, contents; shared state in `state.js`). The native side is `ContentsPopover.swift`, `OverlayViews.swift`, `PageTurnView.swift` and `ImageZoomView.swift`. `ReaderViewController` is split by job into `ReaderViewController+*.swift` (messages, input, page turn, contents, menu, pictures).

## Build and test

```sh
swift test --package-path PlatenCore                       # core unit tests
xcodebuild -project PlatenReader.xcodeproj -scheme PlatenReader \
  -configuration Debug -derivedDataPath build/DerivedData build
python3 scripts/make-fixtures.py                           # regenerate corpus
scripts/check-corpus.sh                                    # corpus must stay green
scripts/run-debug.sh "$PWD/Fixtures/generated/novel.epub" "platen.next();@toggleContents:"
# → log lines with open timings; PNG snapshots in build/snaps/
xcodebuild -project PlatenReader.xcodeproj -scheme "PlatenReader iOS" -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build                            # iOS app
scripts/run-ios-debug.sh Fixtures/generated/novel.epub "@tap:right;@tap:centre"
# → opens the book in the Simulator; log lines; screenshots in build/snaps-ios/
```

`run-debug.sh` relies on Debug-only hooks (`DebugHooks.swift`). `PLATEN_SNAPSHOT_DIR` writes snapshots after the first render: `<book>-N.png` of the web view and `<book>-N-native.png` of the native views (the native one is taken 0.5 s later). `PLATEN_STEPS` runs semicolon-separated steps, one per second:
- JavaScript, such as `platen.next()`. `platen.view` exposes the foliate view; string results are logged as `step result:`.
- `@<selector>` sends a menu action, such as `@toggleContents:` or `@findNext:`.
- `@search:<query>` runs a search; `@tab:<contents|bookmarks|search>` opens the panel on a tab.
- `@ax` logs the window's accessibility tree as VoiceOver sees it (lines starting `ax:`).
- `@resize:<w>x<h>` resizes the window and logs how long re-layout took.

UI tests (`PlatenReaderUITests`, run by `xcodebuild test -scheme PlatenReader -only-testing:PlatenReaderUITests`) drive the real app and read the page through its VoiceOver "page" element. `PLATEN_TEST_HOME` (Debug builds) sends settings, positions and bookmarks to a throwaway place; keep using it for anything automated. `scripts/measure-performance.py <book> [<second book>]` times a Release build against the spec's performance targets.

The screen-control tools may lack macOS permissions in this environment, so verify UI through these snapshots.

## Rules

- **The robustness corpus must stay green.** Every case in the spec's "Format support and robustness" table needs a fixture and a passing check. Add a fixture with every bug fix.
- Swift owns files, parsing and state; JS only drives foliate-js. Book bytes go down through the scheme handler, and events come back up through `post()` → `WKScriptMessageHandler`.
- Book scripts must never run, and remote loads must never happen. Both the CSP on the shell (inherited by foliate's blob iframes) and the WKContentRuleList enforce this. `Fixtures/generated/scripted.epub` and `remote-resource.epub` check them.
- Font obfuscation is undone in Swift (`FontDeobfuscator`), and `encryption.xml` is then hidden from foliate-js so it is not undone twice.
- No telemetry, no network and no permission prompts. Settings are global, and the only per-book data is position and bookmarks (`docs/per-book-data.md`).
- Comment liberally: explain what and why for a non-specialist. User-facing strings go in String Catalogs (development language en-GB).
- Add a line to `scripts/check-corpus.sh` for every new fixture.
- If you patch vendored foliate-js, record it in `PlatenReader/Web/foliate/VENDORED.md`.

## Status

M0 (spike) is done. Launch (1.0) is the Mac app as a DMG (with Sparkle) plus the iOS app on the App Store, both with PDF; the Mac App Store build comes later. M3 (iOS and iPadOS) has started, with the user's go-ahead: the plan and its phases are in `docs/m3-ios-plan.md`; phase 1 (the iOS target, the shared folder and a minimal reader) is done. On macOS 26 / iOS 26 and later the overlay uses Liquid Glass, with the existing materials as the fallback. M1 is in progress: work happens on branch `m1` and is merged into `main` through pull requests (CI runs on them); see "Not yet done" in README.md.
