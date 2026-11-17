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
- Info.plist: the same document types and imported UTIs as the Mac, plus `LSSupportsOpeningDocumentsInPlace`, a scene manifest (several windows on iPad), and `UIFileSharingEnabled` so the app's own folder shows in Files (handy for testing; books still open in place wherever they are).
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
| Home screen and document picker, scenes, security-scoped access, status bar and home indicator, touch swipe, `UIKeyCommand`s, edit menu, settings sheet | iOS | New |
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
- **From testing on an iPhone 16 Pro Max (14 Nov):** text size works again (Smaller and Larger shared one form row, so on iOS both fired at once; they now have their own 44-point targets); Scroll or pages is one setting for every book and PDF on both platforms (no longer per book); the curl's leaf has a plain back in the theme's colour (paper white for PDFs) instead of the system's see-through white, and in PDFs only the page curls; PDFs sit on an ambient background made from their own colours (`PDFAmbientBackground`, iOS only so far: a 12 by 16 pixel drawing per page, off the main thread, blurred and stretched); both bookmark icons are a little wider.
- **From device testing (14 Nov, second round):** PDFs get One Page, Two Pages (a spread in landscape only) and Scroll, chosen from a ticked list rather than a segmented control; long press on a PDF picture saves it to Photos or Files or shares it; the bookmark ribbon is drawn as cloth (a gradient, darker edges, a shadow), a little larger, and in PDFs lies over the bookmarked page's top edge rather than the screen's corner. Rotation stuck after the first page curl: the curl's page view controller was removed inside its own completion block, before UIKit turned autorotation back on; it is now removed on the next run-loop turn (`PageTurnAnimator`), and a curl cut short by another turn is hidden and left to finish. The Layout and Aa popovers are plain rows on the popover's glass, sized to fit (a grouped form drew a second panel inside it). PDF pages in One Page and Two Pages fill the screen's width or height: PDFKit's own fit kept clear of the safe areas, so the fit is worked out against the whole screen (`fillScreen`). PDF swipes follow the finger through PageTurnAnimator (as in books) instead of PDFKit's page view, so a new page arrives already fitted; the ambient background, pages and ribbon move together in one container, and the neighbouring pages' backgrounds are made ahead. In a spread the curl turns one page about the spine, as in a book. In landscape on iPhone the top controls sit 14 points down and the bottom ones just clear of the home indicator.
- **Opening progress (15 Nov):** while a book opens, a slim loading bar with a line saying what is happening (`Shared/OpeningProgress.swift`: downloading from iCloud, opening the book, preparing the pages, laying out the first page), shown only if opening takes more than about a third of a second. Of the about 4 s a book takes to open in the Simulator, about 3 s is still the first-chapter frame stall (see "Phase 1 findings"); fixing that, and a launch animation in place of the bar, are still to do. The folder view says "Looking for books…" until a folder has been read, and counts covers as they are made.
- **Home tabs and search (15–16 Nov):** the home screen has three tabs whose bar stays on screen inside folders: Home (the welcome, for now; what Home should show is still to decide), Recent Books (covers of books opened from anywhere, copies kept so they show when the book cannot be reached; unreachable ones greyed with a mark) and Recent Folders (a list; a folder opens inside the tab). A long press removes an item from either list (`Shared/Recents.swift`, `HomeTabs.swift`). Folder grids have a search button (the field filters by file name, title and author as you type) and a filter by kind of book (EPUB, KEPUB, MOBI, AZW/AZW3, PDF, plain text; at least one stays on). Choose Folder… (on Home, and + in Recent Folders) adds a folder to Recent Folders and opens it there; + in Recent Books opens a book. Recent folders show where they are kept (an icon for this device, iCloud Drive, a network share, a drive) and their path, its end always visible; each is checked in the background with a time limit, so a share that has gone away shows as not connected instead of freezing the app (folder watching, and the old Home folder's bookmark, no longer touch the disk on the main thread). Each folder has its own queues (one share that hangs no longer stops every folder loading), keeps its last listing (`FolderListingCache`, so it shows at once), and decodes covers only for the tiles on screen, at the size shown, in a cache the system can empty (`CoverImages`; holding every cover at full size took hundreds of megabytes in a big folder). Recents checks run on GCD with a time limit that really answers (a task group waits for its slowest task). The folder view has no Back button and an inline title; a swipe anywhere goes back (`SwipeBack.swift`). The three sections sit side by side in a paging scroll view and slide under the finger, with a tab bar of Platen's own on glass (`HomeTabBar`); inside a folder the row stands still and a swipe right goes back. Recent items are removed with a long press (a row swipe would fight the sliding row).
- **Reader polish (16 Nov):** a start-up animation (`LaunchSplash`: the mark and name spring in; going straight to a book it shows the book's progress until the first page, in a window of its own above the reader); a held picture in a book offers Save to Photos, Save to Files and Share, as in PDFs (`platen.pictureAt`, `offerPicture`); body text comes out at the size chosen whatever the book's CSS sets it to (measured per chapter, `normaliseBodyTextSize`, on the Mac too); a page that is one picture fills the page; an Ambient Light switch in Aa for PDFs; Settings as plain rows, with green switches (the reader's tint made an "on" switch white on white in dark mode) and a line on what hyphenation does; the opening bar goes as soon as the page is shown. Ambient light for EPUBs is still to do.
- **Round four (17 Nov):** PDFs: Two Pages re-decides at each turn whether the pages on show can pair (a PDF reopened on a wide page stayed single); a pinch zoom is kept as the page turns (PDFKit resets the scale on a page change, so the reader's zoom is remembered from the pinch itself); a double tap in the centre goes back to the fitted size; Invert Colours in Aa (a white layer with a difference blend over the pages, the background behind them set to the theme's opposite); a wide page alone in landscape curls about its middle like a spread, whose leaf shows the new page's left half on its back. Books: ambient light (Aa > Ambient Light, every theme but Black): the page is see-through, and a glow made from a small snapshot of it shows towards the screen's edges. Folder grids: pinch for 2 to 5 covers across (3 to 8 on iPad), shared with Recent Books; Sort By name, date modified, date created or size.
- **Picture-only pages (17 Nov):** a book page that is just one picture is shown natively (`lonePictureView`), as large as the screen allows, touching its sides or its top and bottom, with no bars: inside the web page the margins kept it small, and dark themes' picture backing drew grey bars. The page sends the picture once per chapter (`lonePicture` message) and hides its own copy; page turns and the ambient glow photograph the page with the picture drawn in (`pageSnapshot`).
- **Ambient light arrives with the page (17 Nov):** in books the glow is made before a turn animates (the new page is laid out underneath, its picture settled through `lonePictureState`, then `makeGlowNow` snapshots it), and it sits inside the page area, so slides and curls carry it with the page instead of it popping in afterwards. In PDFs a curl crossfades the glow from the old page's to the new one's over the curl's own 0.5 seconds (`PageTurnAnimator.curlDuration`), finishing as the curl lands; slides and swipes move it with the page.
- **Footnote pop-ups** on both platforms (shared web code, `modules/footnotes.js`).
- **Text and margins:** the default size follows Dynamic Type (20 pt at the standard size) until the reader picks one; 24-point side margins on iPhone; top and bottom margins clear of the Dynamic Island and home indicator, steady when the status bar comes and goes.
- **Home screen of Platen's own (14 Nov):** `HomeViewController` replaced `UIDocumentBrowserViewController` as the window's root. It reopens the last book (the `lastOpenBook` bookmark), else shows the welcome; "Open Book…" is `UIDocumentPickerViewController`, opening in place; books from other apps go straight to the reader. Then the folder view on it: a grid of covers of the folder the last book came from, inside a folder the reader chooses once (`LibraryFolder`, a bookmark); covers from PlatenCore's `BookCover` (EPUB, PDF first page), cached in Caches; iCloud placeholders fetched on tap; the folder watched for changes. Still to do: MOBI/AZW3 covers, and perhaps a Thumbnail extension so Files shows covers too.

### Phase 2: shared reader session (done)

Done on 14 Nov 2026, with more than was planned here:

- **`Shared/BookSession`** holds everything about an open book for both apps: loading, the record, the bridge, bookmarks, search, jumps, saving, the navigation policy and recovery when WebKit's process ends. Each app's `ReaderViewController` is its host (`BookSessionHost`) and keeps only platform work.
- **`Shared/ReaderBridge`** types the bridge: `ReaderMessage` (decoded once), `WebSettings`, `PageTurn`, `ClickZone`. No script strings or `[String: Any]` decoding remain in the view controllers.
- **`Shared/ReaderCommands`** is the one set of commands for books and PDFs; the overlay's and contents panel's actions are built from it once, for all four readers.
- **A base reader class on each platform** (`ReaderBaseViewController`) owns the chrome, spinner, failure message and theme; on the Mac also the keys, click zones and menu actions, which the book and PDF windows used to duplicate. The Mac has a `ReaderChrome` of its own, like iOS.
- **`firstRender` waits for the first chapter to load** (reader.js), so "First page visible" is honest and taps and swipes are ignored until then.
- **WebKit is warmed at launch on iOS** too (`Shared/WebViewWarmer`). Still to measure on a real iPhone; the first-chapter stall in the Simulator remains (about 4 s).
- **Unit tests for the shared code** (`PlatenReaderTests`, run in CI): the test bundle compiles `Shared/` on its own, which also proves it needs nothing from either app. This replaces the `PlatenReaderKit` package idea below: it gives the tests and the isolation without making every shared type public or moving the String Catalog.

Still open from this phase: picture zoom, Copy with Citation (the text is shared, in `Citation`), the click-zone explainer and VoiceOver's page text on iOS. The session already delivers what each needs.

The original plan:

Extract `ReaderSession` from the Mac `ReaderViewController` (book loading, record, bridge, message decoding into `ReaderState`, bookmarks, search, jumps, saving), with the Mac view controller as its host. Verify the Mac with `check-corpus.sh` and `run-debug.sh` snapshots before and after. The iOS reader then uses it, so contents, bookmarks, search, the Back button and page numbers arrive on iOS with no new logic.

Once the shared layer has settled, consider turning `Shared/` and `Web/` into a second local package, `PlatenReaderKit`, beside `PlatenCore`. The compiler would then stop AppKit or UIKit code creeping into shared files, and the shared code could have its own tests. It changes how the scheme handler finds the web shell (`Bundle.module`), so it is a separate, contained step.

### Phase 3: overlay and touch

- Move the SwiftUI overlay, contents popover and explainer to `Shared/`; host them in `UIHostingController`. The title strip becomes a top bar with the title, chapter and a Close (back to the home screen) button.
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

### Planned for later: read aloud

A button that reads the page aloud, on the device (no network), agreed on 17 Nov to come later:

1. **First, Apple's voices** (`AVSpeechSynthesizer`, with the system's Enhanced and Premium voices, which the reader downloads in Settings > Accessibility > Spoken Content). No licensing questions and nothing added to the app. Books: from the first word on screen to the end of the page, then the page turns and reading carries on (the shell already finds the page's text for bookmark snippets); the sentence being read is highlighted (the synthesiser reports word ranges). PDFs: PDFKit's page text (scanned PDFs without text have none). Play and pause, speed and voice; keeps reading with the screen locked (background audio).
2. **Then, perhaps, a neural voice bundled in the app**, behind the same button. The candidate is Kokoro-82M (Apache-2.0 weights; about 80–330 MB depending on quantisation; faster than real time on recent iPhones). Before building it, confirm a permissively licensed text-to-phoneme step: many pipelines use eSpeak NG, which is GPL-3 and does not suit the App Store. Each voice's licence is checked too (Piper's voices vary; Coqui XTTS is non-commercial, so out), and the licences go in the app's acknowledgements.

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
