# M3: iOS and iPadOS, implementation plan

This plan implements the spec's "iOS and iPadOS (M3)" section. The decisions there and in "Decisions made" are settled; this document only decides *how*. Each phase ends with the Mac build, `swift test --package-path PlatenCore` and `scripts/check-corpus.sh` still green.

## What we start from

- `PlatenCore` already declares `.iOS(.v17)` and has no AppKit, so it is shared unchanged.
- `PlatenReader/Web/` (the shell, its modules and vendored foliate-js) has no Mac assumptions. Taps in WKWebView on iOS already produce `mousedown` and `click` events, so `input.js`'s click zones, the corner bookmark and picture taps work as they are. It is shared unchanged as a folder resource.
- The SwiftUI views (`OverlayViews`, `ContentsPopover`, `ReadingControlsExplainer`) import no AppKit, so they can be shared with little or no change.
- The Mac `ReaderViewController` mixes two jobs: running a book session (loading the book, the position record, the JS bridge, bookmarks, search and jumps) and AppKit UI (window chrome, key and scroll monitors, the native page turn, menus). The session half is the main thing to factor out.
- `project.pbxproj` is small and uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77), so new targets and synchronised folders can be added by hand cleanly. I will edit it directly and keep its style; you can check it by opening the project in Xcode. The only step better done in Xcode by you is choosing a signing team for running on a real iPhone or iPad (Signing & Capabilities); the Simulator needs none.

## Target layout

**A separate iOS target, not one multiplatform target.** The Mac target, its scheme and the release workflow stay exactly as they are; a multiplatform target would change the Mac target's build settings and file membership under the release workflow. Universal purchase only needs the same bundle ID, which a second target can have.

```
PlatenReader/Shared/          new synchronised folder, member of BOTH app targets
PlatenReader/Sources/         Mac only (unchanged role)
PlatenReader/Web/             folder resource, in both targets
PlatenReader iOS/Sources/     new synchronised folder, iOS target only
PlatenReader iOS/Info.plist
```

- New target **PlatenReader iOS**: product "Platen Reader.app", bundle ID `org.platenreader.PlatenReader` (as the Mac app, per the spec), iOS 17.0, iPhone and iPad, module name `PlatenReader`. Its own shared scheme `PlatenReader iOS`.
- Info.plist: the same document types and imported UTIs as the Mac, plus `LSSupportsOpeningDocumentsInPlace`, `UISupportsDocumentBrowser`, a scene manifest (several windows on iPad), and `UIFileSharingEnabled` so the app's own folder shows in Files (handy for testing; books still open in place wherever they are).
- A shared `Config/Shared.xcconfig` holds what must match on both platforms (version, build number, bundle ID, deployment targets), so the two targets cannot drift apart.
- The String Catalog moves to `Shared/` so both targets extract into one catalog (en-GB).
- The app icon: an iOS asset catalog with the 1024 px Honey icon from `design/icon/`.
- CI gets one more step: build the iOS target for the Simulator with signing off.

## Shared versus platform-specific

| Piece | Where | How |
| --- | --- | --- |
| `PlatenCore` | Package | Unchanged |
| `Web/` shell, foliate-js | Folder resource | Unchanged; any iOS-only behaviour goes behind a setting in the payload (for example "most columns allowed") rather than user-agent sniffing |
| `ReaderSchemeHandler`, CSP, `RemoteContentBlocker`, `WeakScriptMessageHandler` | Shared | Moved as they are (Foundation and WebKit only) |
| `ReaderState` | Shared | Moved as it is |
| `ReaderSettings` model and enums | Shared | AppKit parts (`NSColor`, `NSAppearance`) move to a Mac extension file; `theme(for:)` becomes `theme(systemIsDark:)` with thin Mac and iOS wrappers |
| Book session: load, record, `sendBookIfReady`, `callPlaten`, message decoding, bookmarks, search, jumps, saving | Shared, new `ReaderSession` | Extracted from the Mac view controller in phase 2. Platform effects (click zone, show picture, failure, announcement, first render) go through a small `ReaderSessionHost` protocol |
| Overlay bar, contents popover, explainer, Aa and Layout popovers | Shared SwiftUI | Moved, with `#if os(macOS)` only where a modifier differs |
| Copy with Citation text | Shared | Building the quote and citation is shared; writing to `NSPasteboard` or `UIPasteboard` is per platform |
| Window, chrome, menus, key and scroll monitors, Settings window, welcome window, `NSDocument` | Mac | Unchanged |
| Document browser, scenes, security-scoped access, status bar and home indicator, touch swipe, `UIKeyCommand`s, edit menu, settings sheet | iOS | New |
| Native page turn (Curl, Slide) | Per platform, shared maths | The curl's strip geometry is plain maths and can be shared; the drawing is `NSView` versus `UIView` |
| Picture zoom | Per platform | `UIScrollView` zoom on iOS |

## Phases

### Phase 1: skeleton (this session)

1. Add `Config/Shared.xcconfig` and base both app targets on it. Create `Shared/`, move the scheme handler (with blocker and weak handler), `ReaderState`, the settings model and the String Catalog into it; split the AppKit parts of the settings into `Sources/ReaderSettings+AppKit.swift`. Add `Shared/` to the Mac target. No change in Mac behaviour.
2. Add the iOS target, Info.plist, asset catalog and scheme to the project.
3. A minimal iOS app: a scene delegate with `UIDocumentBrowserViewController` as the home screen (opening in place, no document creation), and a UIKit `ReaderViewController` with the same WKWebView setup (scheme handler, CSP, remote-load blocker, navigation policy). It opens the book under security-scoped access through `Book.open(url:coordinated:)`, restores and saves the position, turns pages on side taps, and has a temporary Close button. "Open in Platen" from other apps opens through the same path. A Debug-only launch argument opens a given path, for testing.
4. Exit: the iOS target builds; `novel.epub` opens in the Simulator at the saved position and pages turn; Mac build, core tests and corpus green; CI builds both.

### Done ahead of plan (after phase 1)

At the user's request, parts of phases 2 to 4 came forward:

- **Shared decoding:** messages that only update what the overlay shows are decoded once, in `Shared/ReaderState+Messages.swift`, for both apps; bookmarks are added through `BookRecord.addBookmark(from:)`. The rest of phase 2 (a whole `ReaderSession`) is still to do.
- **The overlay on iOS:** the Mac's bar, contents, Aa and Layout popovers moved to `Shared/` and are hosted on iOS, drawn in parts (`OverlayBar.Part`) as floating pieces of glass with no panel: a round Close button with the title and chapter at the top left (no navigation bar); Contents, Bookmark, Layout, Aa and Settings (the gear opens `ReaderSettingsView` in a popover) as one group at the bottom right, above the slider; the slider (no glass) between round ‹ › buttons, with the location in small text below it, in place of the page number. Turns past the start or end show a notice ("End of book"). PDFs get the Layout button too (Pages or Scroll), and their controls are always light.
- **Page turns are drawn natively** (`PageTurnAnimator`, for both the book and PDF readers): a picture of the page is laid over it, the page turns instantly underneath, and Core Animation slides or curls the picture away at the screen's full rate (120 Hz on ProMotion iPhones, with `CADisableMinimumFrameDurationOnPhone`). Swipes in books follow the finger the same way; foliate's own touch dragging is off on iOS (`native-swipe`, a patch in `paginator.js`), because dragging in JavaScript was held to 60 frames a second and stuttered on a device. Taps, buttons and keys slide or curl as Settings > Page Turn says; swipes always slide. PDFs curl or slide on taps too; their portrait swipes are PDFKit's own.
- **Liquid Glass on iOS 26 and later** for the bar and the top controls (one glass container), with the material on older systems (`Shared/GlassSurface.swift`). The Mac still uses the material: its glass waits for a check on screen, since the debug snapshots draw offscreen, where glass does not appear.
- **Settings sheet** holds only what the popovers do not (the layout new books open in, line width, page turn, pages left, hyphenation, clearing data); text size, font, line spacing and appearance stay in Aa.
- **Line width on phones** sets the side margins (Narrow 44, Medium 24, Wide 12 points), because the character caps (about 55, 66, 80) are all wider than an iPhone screen.
- **Plain text (.txt)** opens on iOS as on the Mac (PlatenCore's TextBook).
- **iPhone layout:** books always show one page on iPhone; Two Pages is not offered there. iPad keeps the width rule (two pages in landscape and wide Split View windows).
- **Hardware keyboard:** the Mac's shortcuts as titled UIKeyCommands, listed in the iPad ⌘ overlay.
- **Page Curl on iOS** for taps, the ‹ › buttons and keys: snapshots before and after an instant turn, curled by UIPageViewController. Swipes slide; a curl that follows the finger is still to do (it can build on the swipe's picture-over-the-page approach).
- **Footnote pop-ups** on both platforms (shared web code, `modules/footnotes.js`).
- **Text and margins:** the default size follows Dynamic Type (20 pt at the standard size) until the reader picks one; 24-point side margins on iPhone; top and bottom margins clear of the Dynamic Island and home indicator, steady when the status bar comes and goes.

### Phase 2: shared reader session

Extract `ReaderSession` from the Mac `ReaderViewController` (book loading, record, bridge, message decoding into `ReaderState`, bookmarks, search, jumps, saving), with the Mac view controller as its host. Verify the Mac with `check-corpus.sh` and `run-debug.sh` snapshots before and after. The iOS reader then uses it, so contents, bookmarks, search, the Back button and page numbers arrive on iOS with no new logic.

Once the shared layer has settled, consider turning `Shared/` and `Web/` into a second local package, `PlatenReaderKit`, beside `PlatenCore`. The compiler would then stop AppKit or UIKit code creeping into shared files, and the shared code could have its own tests. It changes how the scheme handler finds the web shell (`Bundle.module`), so it is a separate, contained step.

### Phase 3: overlay and touch

- Move the SwiftUI overlay, contents popover and explainer to `Shared/`; host them in `UIHostingController`. The title strip becomes a top bar with the title, chapter and a Close (back to browser) button.
- The touch table: side taps turn, centre tap toggles, corner tap bookmarks, link taps follow, picture tap zooms (native `UIScrollView`), long press selects (WebKit's own). The ribbon outline shows while the overlay is up.
- Horizontal swipe that tracks the finger, finishing with the chosen animation (Page Curl, Slide or None), built on the native page-turn view ported to UIKit with shared geometry. No override on touch.
- The status bar and home indicator hide with the overlay. The first-run explainer, as on the Mac.

### Phase 4: layout and settings

- Two pages only on iPad in landscape; iPhone in either orientation and iPad in portrait show one page; Split View and Slide Over use the window width. Sent to the shell as a setting, decided in Swift from size class and window shape.
- Default text size follows Dynamic Type until the reader changes it, then their choice is kept.
- Themes follow the trait collection (Automatic) or the chosen theme.
- Aa and Layout popovers as on the Mac, plus a settings sheet with General, Appearance and Clear reading positions and bookmarks.

### Phase 5: selection, keyboard and accessibility

- The edit menu gains Copy with Citation, Search Book for "…" and Share, beside Copy, Look Up and Translate (`buildMenu` / `WKUIDelegate` edit-menu hooks).
- Hardware keyboard: the Mac shortcuts as `UIKeyCommand`s with titles, so they appear in the iPad ⌘ overlay.
- VoiceOver: reuse `accessibility.js` page text; label overlay controls; check focus is not trapped.

### Phase 6: Liquid Glass, windows and polish

- Liquid Glass on iOS 26 and later (`glassEffect` in the shared SwiftUI, `UIGlassEffect` for UIKit surfaces), with materials on iOS 17 to 25. The shared SwiftUI change also gives the Mac its Liquid Glass (an open README item), with `NSGlassEffectView` for its AppKit surfaces.
- Several windows on iPad (one scene per book) and state restoration.
- An iOS corpus check: a script that opens each fixture in the Simulator through the Debug launch argument and checks the logged result, mirroring `check-corpus.sh`.
- Performance: measure open and rotation re-layout on the iPhone 15 Pro Max against the spec's targets.

### Later, outside this plan's code work

The Mac App Store build (sandbox checks, container migration), App Store Connect, signing and TestFlight are being set up separately, as the spec says.

## Phase 1 findings

- **The first chapter after launch is slow to appear in the Simulator.** Its iframe takes about 3.5 s from `src` being set to its `load` event; later chapters, and the same book reopened in the running app, load in 17–30 ms or about 2 s respectively (the Mac: well under 0.5 s). The book itself is read in about 120 ms and every `platen://` fetch takes 0–2 ms; WebKit's log shows the blob: main-resource load advancing in steps about a second apart. Not caused by the remote-load blocker, the app's main thread (idle in a sample), or the scene state (foreground-active). It looks like WebKit warming up, which the spec already asks us to do at launch ("Warm the WebKit content process"). Measure on a real iPhone, then warm WebKit (a hidden web view loading the shell and a tiny blob: iframe at launch) as the first job of phase 2.
- **`firstRender` is posted too early.** foliate's first `relocate` comes before the chapter's iframe has loaded, so "First page visible" is logged while the page is still blank. Harmless on the Mac, where the gap is a few milliseconds; phase 2 should post `firstRender` after the section's `load` and ignore turns until then.
- **Taps were lost or misread (fixed in phase 1).** Zones came from the click's position inside foliate's many-pages-wide chapter frame, and WebKit does not turn every tap into a click (taps close together are merged). Taps are now recognised natively (`pageTapped` in the iOS reader); Swift decides the zone from the finger's place on screen and asks the page (`platen.tapTarget`) only whether a link, picture, ribbon or selection was under it. With the `touch` setting, input.js sends no click zones.
- **During the first-chapter stall, WebKit holds all touches** until its web process answers; a touch also ends the stall at once. So nothing can be tapped in the first seconds after opening, in the Simulator at least.
- **Coordinated reads of files on the Mac's own disk stall in the Simulator.** Books in the app's container, or any file provider, open normally. `scripts/run-ios-debug.sh` copies the book into the app's Documents folder for this reason.
- `reader.html` needed a viewport meta tag, or iOS lays the page out 980 pixels wide and shrinks it.

## Risks

- **Security-scoped files on slow providers.** Coordinated reads of SMB or offloaded iCloud files may take seconds; the 500 ms quiet spinner covers it, as on the Mac.
- **Edit-menu customisation** in WKWebView has changed across iOS versions; the iOS 17 fallback may offer fewer items.
- **Swipe tracking over a web view** competes with WebKit's own gestures and text selection; the recogniser must only claim clearly horizontal drags that do not start on a selection handle.
