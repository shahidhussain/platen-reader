# Platen Reader

A free, open source (MPL-2.0), file-first ebook viewer for macOS, with iOS to follow. Double-click a book and you are reading in under a second, with no library, import step or account. The full product and technical spec is in `Platen Reader product and technical spec.md`; read it before making product decisions. Its "Decisions made" table is settled.

## Layout

- `PlatenCore/`: Swift package, platform-neutral (no AppKit, UIKit or WebKit). It holds the zip reader (Zip64, recovery scan), EPUB package parser, cover extraction and cache (`BookCover`, `CoverCache`), DRM detection, font de-obfuscation, path fix-ups, book identity and the per-book position store. Unit-tested. Its second module, `Kokoro`, is read aloud's natural voice (Kokoro-82M on Accelerate), compiled optimised even in Debug builds.
- `PlatenReader/Shared/`: code used by both the Mac and iOS apps. A synchronised folder in both app targets (and compiled on its own by the `PlatenReaderTests` unit tests). Nothing here may import AppKit or UIKit; platform parts go in `+AppKit` / `+UIKit` files in each app.
  - `BookSession`: one open book (reading the file, the saved position and bookmarks, the conversation with reader.js, every `platen` command). Each app's `ReaderViewController` is its `BookSessionHost` and adds only what is the platform's own.
  - `ReaderBridge`: everything that crosses the JS bridge, typed: `ReaderMessage` (decoded once from `post()`), `WebSettings`, `PageTurn`, `ClickZone`. Add a case here when reader.js gains a message; never decode `[String: Any]` elsewhere.
  - `ReadAloudStarter`: the speaker button's logic for both apps (start, pause, the first-time voice question, restarting after a turn by hand); each app's `ReaderBaseViewController` is its `ReadAloudHost` (alerts, the download sheet, Now Playing).
  - `ProblemReport` and `ErrorCode`: Report This Book and Send Feedback (subject tag, diagnostics file); each app's `ProblemMail` writes the email. Addresses are in `AppLinks` (placeholders until the site exists).
  - `AboutView` and `AcknowledgementsView`: the About screen (a window on the Mac, `AboutWindow.swift`; Settings › About on iOS). The acknowledgements come from `Acknowledgements.json`, made with THIRD_PARTY_LICENSES.md by `scripts/make-acknowledgements.py` from `Licenses/components.json`: when a dependency changes, edit that and run the script (CI checks they are in step).
  - `ReaderCommands`: what a reader can be asked to do, for books (`BookSession`) and PDFs (each `PDFReaderViewController`) alike. The overlay, contents panel, menus and keys go through it.
  - Also the scheme handler (CSP and remote-load blocker), `ReaderState`, the settings model, `PDFReaderModel`, the SwiftUI overlay and contents views, `WebViewWarmer`, `Citation`, the String Catalog and the log.
- `Config/Shared.xcconfig`: the version, bundle ID and minimum OS versions, shared by both app targets.
- `PlatenReader/Sources/`: macOS app (AppKit, with SwiftUI for the overlay and Settings). It is a file-system-synchronised group, so new files need no project edits.
  - `BookDocument`: an `NSDocument`. The reader loads the file itself, in the background.
  - `ReaderBaseViewController`: what every book window has (the controls in `ReaderChrome`, spinner, failure message, theme, keys, click zones, menu actions). `ReaderViewController` (books: WKWebView, host of the `BookSession`) and `PDFReaderViewController` (PDFKit) subclass it.
  - `ReaderSchemeHandler`: serves `platen://reader/app/*` (the shell) and `platen://reader/book/*` (book files from memory). It also holds the CSP and the remote-load blocker.
  - `MainMenu`: the full command set. Actions go to the first responder.
- PDFs are shown by PDFKit, not the web shell: `PlatenCore/PDFIdentity` (identity), `Shared/PDFReaderModel` (outline, page bookmarks, search, position, feeding the same `ReaderState` and overlay), and a `PDFReaderViewController` in each app. Fixture: `Fixtures/generated/outline.pdf`.
- `PlatenReader iOS/`: the iOS and iPadOS app (target "PlatenReader iOS", same bundle ID): `HomeViewController` as the home screen (reopens the last book; else the tabs in `HomeTabs.swift`: Home (the welcome), Recent Books and Recent Folders over `Shared/Recents.swift`, with folders shown by `FolderView.swift` over `Shared/BookFolder.swift`; "Open Book…" is the system document picker), and UIKit readers shaped like the Mac's (`ReaderBaseViewController` with its own touch `ReaderChrome`; `ReaderViewController` for books and `PDFReaderViewController` for PDFs). M3 is planned phase by phase in `docs/m3-ios-plan.md`.
- `PlatenReader/Web/`: `reader.html/js/css`, the shell that drives foliate-js. `foliate/` is vendored at a pinned commit (see `foliate/VENDORED.md`).
- `design/icon/`: the app icon. `make-icons.py` draws it (SVG, in several background colours; Honey is the one in use), Quick Look renders it, and `mask-icon.swift` makes the corners transparent. The sizes live in `PlatenReader/Sources/Assets.xcassets/AppIcon.appiconset`.
- `scripts/`: `make-fixtures.py` (synthetic robustness corpus → `Fixtures/generated/`), `check-corpus.sh` and `check-corpus-ios.sh` (open each fixture, on the Mac and in the iOS Simulator, and check the result; the checks are shared in `corpus-cases.sh`), `run-debug.sh` (headless open + snapshots), `update-foliate.sh`. The Xcode project is maintained in Xcode; `PlatenReader/Sources` is a synchronised folder, so new files need no project edits.
- Reader features live in `reader.js` (opening, the `platen` commands) and `PlatenReader/Web/modules/` (one module per feature: layout, book fixes, input, page numbers, bookmarks, jumps, search, contents; shared state in `state.js`). The native side is `ContentsPopover.swift` and `OverlayViews.swift` (Shared), and `PageTurnView.swift` and `ImageZoomView.swift` (Mac). The Mac `ReaderViewController` is split by job into `ReaderViewController+*.swift` (input, page turn, citation and context menu, menu, pictures).

## Build and test

```sh
swift test --package-path PlatenCore                       # core unit tests
xcodebuild test -project PlatenReader.xcodeproj -scheme PlatenReader -destination "platform=macOS" \
  -derivedDataPath build/DerivedData -only-testing:PlatenReaderTests   # shared-code unit tests
xcodebuild -project PlatenReader.xcodeproj -scheme PlatenReader \
  -configuration Debug -derivedDataPath build/DerivedData build
python3 scripts/make-fixtures.py                           # regenerate corpus
scripts/check-corpus.sh                                    # corpus must stay green
scripts/check-corpus-ios.sh                                # the same corpus on iOS (a few minutes)
scripts/run-debug.sh "$PWD/Fixtures/generated/novel.epub" "platen.next();@toggleContents:"
# → log lines with open timings; PNG snapshots in build/snaps/
xcodebuild -project PlatenReader.xcodeproj -scheme "PlatenReader iOS" -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build                            # iOS app
scripts/run-ios-debug.sh Fixtures/generated/novel.epub "@tap:right;@tap:centre"
# → opens the book in the Simulator; log lines; screenshots in build/snaps-ios/
scripts/ios-matrix.py [--samples] [--only <name>] [--no-build]
# → the iOS reader across themes, ambient light, controls, orientation and layouts,
#   with rules checked on each picture; build/ios-matrix/sheet.png and report.txt
```

`run-debug.sh` relies on Debug-only hooks (`DebugHooks.swift`). `PLATEN_SNAPSHOT_DIR` writes snapshots after the first render: `<book>-N.png` of the web view and `<book>-N-native.png` of the native views (the native one is taken 0.5 s later). `PLATEN_STEPS` runs semicolon-separated steps, one per second:
- JavaScript, such as `platen.next()`. `platen.view` exposes the foliate view; string results are logged as `step result:`.
- `@<selector>` sends a menu action, such as `@toggleContents:` or `@findNext:`.
- `@search:<query>` runs a search; `@tab:<contents|bookmarks|search>` opens the panel on a tab.
- `@ax` logs the window's accessibility tree as VoiceOver sees it (lines starting `ax:`).
- `@resize:<w>x<h>` resizes the window and logs how long re-layout took.
- `@snapwindows` saves every visible window (Settings, the Contents popover…) as `windows-window-<n>-<name>.png`; `@settings:<tab>` opens Settings on a tab; with no book, the welcome window is saved as `welcome-window-…png`. Glass does not draw offscreen, so snapshot runs use the material (check glass on screen).
- `platen.measureText()` returns the body text's size, line spacing, column width and characters per line on the page shown.
- `PLATEN_TEST_SETTINGS="lineWidth=narrow,pageLayout=one"` (with `PLATEN_TEST_HOME`) starts from those settings.

UI tests (`PlatenReaderUITests`, run by `xcodebuild test -scheme PlatenReader -only-testing:PlatenReaderUITests`) drive the real app and read the page through its VoiceOver "page" element. `PLATEN_TEST_HOME` (Debug builds) sends settings, positions and bookmarks to a throwaway place; keep using it for anything automated. `scripts/measure-performance.py <book> [<second book>]` times a Release build against the spec's performance targets.

The screen-control tools may lack macOS permissions in this environment, so verify UI through these snapshots.

## Rules

- **The robustness corpus must stay green.** Every case in the spec's "Format support and robustness" table needs a fixture and a passing check. Add a fixture with every bug fix.
- Swift owns files, parsing and state; JS only drives foliate-js. Book bytes go down through the scheme handler, and events come back up through `post()` → `BookSession` (as a `ReaderMessage`).
- Anything both apps need about an open book goes in `BookSession` or `ReaderCommands`, not in a view controller. Add a test in `PlatenReaderTests` for new shared logic.
- Book scripts must never run, and remote loads must never happen. Both the CSP on the shell (inherited by foliate's blob iframes) and the WKContentRuleList enforce this. `Fixtures/generated/scripted.epub` and `remote-resource.epub` check them.
- Font obfuscation is undone in Swift (`FontDeobfuscator`), and `encryption.xml` is then hidden from foliate-js so it is not undone twice.
- No telemetry, no network and no permission prompts. (Sparkle's update check in the direct-download Mac build is the agreed network exception. So is the one-time download of read aloud's natural voice, made only when the reader agrees to it in a dialog that says plainly what it is, with a progress sheet: `docs/read-aloud.md`.) The one agreed permission exception: Save to Photos (long press on a PDF picture, iOS) asks once for add-only photo access, only when the reader chooses it. Settings are global, and the only per-book data is position and bookmarks (`docs/per-book-data.md`), plus the agreed exception of the iOS Recent Books and Recent Folders lists (bookmarks, names and cover copies; see that file).
- Comment liberally: explain what and why for a non-specialist. User-facing strings go in String Catalogs (development language en-GB).
- Add a line to `scripts/corpus-cases.sh` for every new fixture (both corpus scripts read it).
- Before pushing a change to the iOS reader (its look, the glow, the controls, layouts), run `scripts/ios-matrix.py` and look at `build/ios-matrix/sheet.png`; with `--samples` it also takes the books in `samples/` (never committed) through it. A bug found on a device that a rule could have caught becomes a rule there, or a state in one of its cases.
- If you patch vendored foliate-js, record it in `PlatenReader/Web/foliate/VENDORED.md`.
- Read aloud's natural voice (`PlatenReader/Shared/Kokoro`, docs/read-aloud.md) runs Kokoro-82M with our own code on Accelerate (`KokoroModel`): no machine-learning runtime, so nothing that could send telemetry. Keep it that way (ONNX Runtime was tried and dropped for its size and Microsoft telemetry). The voice pack is built by `scripts/make-kokoro-pack.py` from pinned, hashed sources (needs numpy); `scripts/check-no-network.sh` checks that reading with it opens no connection. Nothing GPL may be added (no eSpeak NG).

## Status

M0 (spike) is done. Launch (1.0) is the Mac app as a DMG (with Sparkle) plus the iOS app on the App Store, both with PDF; the Mac App Store build comes later. M3 (iOS and iPadOS) has started, with the user's go-ahead: the plan and its phases are in `docs/m3-ios-plan.md`; phases 1 and 2 (the iOS target, and the reader session both apps share) are done, with much of the later phases' overlay, page turns and settings. On macOS 26 / iOS 26 and later the overlay uses Liquid Glass, with the existing materials as the fallback. M1 is in progress; see "Not yet done" in README.md.

Work happens on short-lived branches cut from the latest `origin/main` and is merged back through pull requests (CI runs on them); there is no long-lived development branch. Several chats may be working at once, so fetch and compare with `origin/main` before starting a change and again before committing.
