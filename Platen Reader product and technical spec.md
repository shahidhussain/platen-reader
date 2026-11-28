# Platen Reader: product and technical spec

Nov 8, 2026 · @Shahid

## Overview

Platen Reader is a free, open source ebook viewer for macOS (and later iOS) that behaves like Preview or IINA: double-click a file and you are reading it within a second, with no library, no import step and no account.

The gap it fills: existing open source readers (Thorium, Readest) are built around a bookshelf and run on Electron or Tauri. Platen is native, file-first and gets out of the way. Its primary format is EPUB in all its variants, with MOBI, AZW3 and KEPUB alongside.

**Principles**

- **Files are the library.** Folders in Finder, iCloud Drive and network shares are where books live. Platen never imports, copies or catalogues them.
- **Transparent by default.** On open, the window shows only the page. Controls appear on request and leave again.
- **Fast everywhere.** Local, iCloud and SMB files all open quickly, and a dropped network connection never interrupts reading.
- **Robust to real-world files.** Malformed, old, odd and publisher-specific EPUBs open, or fail with a clear explanation.
- **Mac conventions first.** Menus, shortcuts, window behaviour and accessibility follow the platform, and the overlay stays sparse because the menu bar carries the full command set.
- **Minimal state.** Settings are global. The only per-book data is reading position and bookmarks.

## Decisions made

These are settled and should not be revisited without a reason.

| Topic | Decision | Why |
| --- | --- | --- |
| Name | Platen Reader | A platen presses the page against the type. The name is free on App Store Connect; the unrelated iOS app "Platen: Paper & Ink" is not a concern. |
| Licence | Mozilla Public License 2.0 | Changes to Platen's own files stay open; compatible with the App Store, unlike the GPL. |
| Platforms | macOS first, then iOS and iPadOS | Shared core from day one so iOS is an addition, not a port. |
| Distribution | Launch (1.0): the Mac app as a direct download (notarised DMG on GitHub releases, plus a Homebrew cask) and the iOS and iPadOS app on the App Store. The Mac App Store build comes later | Avoids sandbox constraints on file associations and network access in the Mac release. Decided 12 Nov 2026. |
| Updates (direct download) | Sparkle, in the direct-download Mac build only. It checks for updates automatically by default (the user can turn this off), using an appcast on a permanent GitHub Pages site. App Store builds update through the store and contain no Sparkle code | Keeps direct-download users current without a Homebrew dependency. The check is the only network request Platen makes, and it sends no system profile. Decided 12 Nov 2026. |
| App Store identity | One bundle ID shared by Mac and iOS (universal purchase) | One listing, one purchase (free), one set of reviews. The direct-download Mac build keeps the same bundle ID. |
| Age rating | 4+ (the lowest rating) | Platen ships no content and has no web browsing; it only shows files the user already has, and book remote loads are blocked. |
| App Store privacy label | Data Not Collected | No telemetry, no network, no accounts. (App Store builds have no update check.) |
| Minimum OS | macOS 14 Sonoma, iOS 17 | Keeps SwiftUI and WebKit APIs modern and the code simple. |
| Overlay material | Liquid Glass on macOS 26 and iOS 26 and later, on both platforms; the current translucent materials on older systems | Matches the system's own controls on current OSes without raising the minimum OS. |
| Formats | EPUB 2 and 3 (reflowable and fixed layout), KEPUB, MOBI, AZW3, DRM-free only, plain text (.txt) and PDF, on Mac and iOS alike | PDF is in the launch scope (brought forward from M4 on 12 Nov 2026) and uses PDFKit; KFX and DRM-protected files unsupported. |
| Rendering engine | foliate-js (MIT) inside WKWebView | Proven pagination, fixed layout and format support; licence-compatible. |
| Price | Free |  |
| Telemetry | None of any kind |  |
| Read aloud | A speaker button reads the book aloud from the current page with Apple's voices (AVSpeechSynthesizer), preferring Premium, then Enhanced, then default voices for the book's language (its `dc:language`, else the language of its text), underlining the word being read (not highlighting it) and turning pages. iOS first; the Mac follows with the same shared code (done 24 Nov 2026: the speaker on the overlay bar, View › Read Aloud ⌘R) | Natural reading on the device with nothing to download, no account and nothing sent. Decided 22 Nov 2026. A natural English voice (Kokoro-82M) was built and then parked the same day: see Parked below and docs/read-aloud.md. |
| Language | English at launch, all strings localisable |  |
| Folders on the Mac | A Home window with a sidebar of the folders the reader chooses and their books as covers, as on iOS (1.1, after the Mac 1.0 download). The Mac keeps the list of chosen folders (`recents/folders.json`); Recent Books there is the system's own Open Recent list, so nothing more is stored. Plan: docs/mac-folder-view-plan.md | Asked for after the first DMG test, when the Mac's welcome window had no "Choose Folder…". Without the list, Home would forget the folder at every launch. Decided 28 Nov 2026. |

## The happy path

The user double-clicks a book anywhere (local disk, iCloud Drive, SMB share) and sees its text in under a second, at the place they last stopped reading.

**Opening**

- Platen is a document-based app. Each book opens in its own window; Open Recent, window restoration, tabs and Finder "Open With" come from the system.
- There is no loading screen. If an open takes longer than 500 ms (typically an iCloud file that has been offloaded, or a slow share), show a small, quiet progress indicator centred in the empty window.
- Books up to 50 MB are read into memory in one sequential read, then never touched again. This makes network shares fast and means a sleeping NAS or dropped connection cannot interrupt reading.
- Larger books (illustrated or fixed-layout) are read lazily, one zip entry at a time, through a seekable file handle.
- Nothing is unzipped to disk. Book contents are served from memory to the web view through a custom URL scheme handler.
- The first visible section renders before the rest of the book is processed. Table of contents parsing, search indexing and total-length estimation happen afterwards, in the background.

**Remembering position**

- Reading position is stored as an EPUB CFI (Canonical Fragment Identifier), which points to a location in the text rather than a page. It survives window resizing, font changes and switching between paginated and scroll modes.
- A book is identified by its OPF unique identifier combined with a fast fingerprint: file size plus a hash of the first and last 64 KB. This avoids hashing whole files over the network, and survives renames and moves.
- Position is saved on every page turn (debounced) and when the window closes.
- A book with no saved position opens at the start of the main text where the EPUB marks it, otherwise at the first spine item.

**Failures**

- DRM-protected books are detected (encryption entries that are not font obfuscation) and show a plain message naming the likely DRM type, not a blank page.
- Corrupt files show what failed and, where possible, still open whatever sections can be read.
- The DRM message links to a short guide on the Platen site explaining DRM and where to get DRM-free books.
- Any book that fails to open shows an error screen with a **Report this book** button. It opens a pre-filled email to the support address, with a subject tag such as `[Platen 1.0.2 · macOS · E-1042]` and an attached diagnostics file: app version, OS and device, the parse error, EPUB version and the generator named in the book. The user sees the email before sending it. Attaching the book itself is an option, off by default. On the Mac this uses the sharing service (`NSSharingService` compose email); on iOS the system mail composer.
- Help > Send Feedback… opens a blank email to the same address with the app version and OS in the subject tag. Nothing is sent without the user pressing Send. On iOS it is in Settings.
- As built (24 Nov 2026): error codes are E-1001 to E-1009 for DRM (by scheme), E-1010 KFX, E-1020 not an ebook, E-1030 damaged, E-1040/1041 PDF unreadable/locked, E-1050 the file could not be read, E-1099 anything else; never reused (`ErrorCode`). The diagnostics file also carries the app's recent log, which leaves out titles and file names; system errors appear only as domain and code, since their messages name the file. A DRM book gets the guide link and no report button. The addresses are in `AppLinks`, all real since 27 Nov 2026: the website, the DRM guide (`…/projects/platen-reader/support/#drm`) and the privacy policy are pages of Platen Reader's section of the author's site, kept at those addresses for good, and the support address is the one the site gives.

## Reading modes and layout

Reflowable books have two modes, paginated (the default) and continuous scroll; fixed-layout books are always paginated. The mode is one setting for every book and PDF: choosing Scroll or pages in any book changes it, books already open follow, and every book opens in it (decided 14 Nov 2026; it was remembered per book before).

**Paginated (default)**

- Text is laid out in pages that turn left and right, like a book.
- One Layout setting chooses One Page, Two Pages or Scroll (⌘1, ⌘2, ⌘3). Two Pages shows two pages side by side whenever each column can hold a comfortable line length (roughly 50 or more characters at the current font size), otherwise one, as in Apple Books; Settings and the Layout popover say so when the window is too narrow. On the Mac the two pages are set as a book's spread: a gutter of about three ems between them whatever the window's width, the line length of the Line Width setting (about 55, 65 or 75 characters), and in a wide window the text up to a fifth larger rather than small type in wide margins; what is left over goes to the outer margins. The top and bottom margins hold a whole number of lines, so the text sits centred on the page with the page numbers in the bottom margin.
- In full screen on a typical Mac display this nearly always produces a two-page spread.
- Page turns animate in one of three styles, chosen in Settings: Page Curl (the default; with two pages the leaf bends like paper), Slide (a short horizontal slide of 150 to 200 ms) or None. No animation when the system Reduce Motion setting is on.
- A two-finger trackpad swipe tracks the fingers interactively: the page follows the gesture and completes or springs back on release.

**Continuous scroll**

- The book scrolls vertically as one continuous column. Chapters follow on seamlessly; reaching the end of one loads the next without any action.
- The column is centred with a maximum line length (see Typography), in a window or full screen.
- Scrolling uses the scroll wheel or two-finger trackpad scroll, as on any web page.

**Window**

- Windows resize freely in both dimensions with no aspect-ratio constraint.
- Resizing re-flows the text and keeps the same sentence in view (anchored by CFI). Re-pagination is debounced so dragging a window edge stays smooth.
- Standard full screen (green button, View menu, ⌃⌘F).

**Fixed-layout books**

- Each page is shown whole, scaled to fit the window, like a PDF page.
- Two-page spreads follow the publisher's page-spread properties (left and right page placement) when the window is wide enough.
- Font, size and line-spacing settings do not apply. Themes only colour the background around the page.
- Scroll mode is unavailable; the menu item is disabled with a tooltip explaining why.

## Interaction model

A plain click is the main control: in paginated mode the left third goes back, the right third goes forward and the centre toggles the overlay; in scroll mode a click anywhere toggles the overlay.

**Mouse and trackpad (macOS)**

| Input | Paginated | Scroll |
| --- | --- | --- |
| Click, left third | Previous page | Toggle overlay |
| Click, centre third | Toggle overlay | Toggle overlay |
| Click, right third | Next page | Toggle overlay |
| Click on a footnote or endnote reference | Show the note in a pop-up (click elsewhere or Esc closes it) | Same |
| Click on any other link (cross-reference) | Follow link | Follow link |
| Click in the top-right corner of a page | Add or remove bookmark | Add or remove bookmark |
| Click-drag, double-click, triple-click | Select text, word, paragraph | Select text, word, paragraph |
| Right-click | Context menu | Context menu |
| Force click or three-finger tap | Look Up definition | Look Up definition |
| Two-finger horizontal swipe | Turn page, tracking the fingers | (none) |
| Scroll wheel or two-finger vertical scroll | Turn page | Scroll |
| Pointer moves to the top edge | Reveal title bar and window buttons | Same |

A "click" means mouse-down and mouse-up with negligible movement. Show the overlay on the first click immediately; if a double-click follows, the selection proceeds normally and the overlay is left as is. There is no separate text-selection mode.

**Keyboard**

| Keys | Action |
| --- | --- |
| ← →, Page Up / Page Down, Space / ⇧Space | Previous / next page (scroll mode: screen up / down) |
| ⌘← / ⌘→ | Previous / next chapter |
| ⌘D | Bookmark this page |
| ⌘T | Show table of contents and bookmarks |
| ⌘F, ⌘G | Find in book, find next |
| ⌘+ / ⌘− / ⌘0 | Larger / smaller / default text size |
| ⌘\[ | Back to previous location (after any jump) |
| ⌃⌘F | Full screen |
| Esc | Hide overlay; exit full screen if the overlay is already hidden |

Every command in the overlay and context menu also exists in the menu bar with its shortcut.

**Overlay**

The overlay fades in over the page (about 150 ms) and hides on the next centre click, on Esc, or after 4 seconds without pointer movement while it is not being used.

On macOS 26 and iOS 26 and later, every overlay surface uses Liquid Glass (SwiftUI `glassEffect`, AppKit `NSGlassEffectView`, UIKit `UIGlassEffect`): the bars, buttons, slider backing, popovers, the click-zone explainer and the title-bar strip. Related controls share one glass container so they blend as the system's do. On older systems the current translucent materials stay. Reduce Transparency and Increase Contrast are honoured through the system's own glass handling.

It contains only:

- **Title bar strip** with the standard window buttons, the book title and the current chapter.
- **Location line**, for example "Chapter 4 · 37%", with the printed page number when the book provides one ("p. 214").
- **Progress slider** across the bottom with chapter boundaries as ticks. While dragging, a label shows the chapter name and percentage.
- **Previous and next page buttons.**
- **Contents button**, shown only when the book has a table of contents or bookmarks.
- **Aa button** opening a small popover for text size, font, line spacing, line width and theme.
- **Back button** ("Back to p. 87" or "Back to Chapter 3"), shown only after a jump through the contents, slider, a link or a bookmark, and kept until the user turns a page past the destination.

**Window chrome**

- The title bar is transparent and hidden, with content extending under it (full-size content view). Window buttons and title appear with the overlay or when the pointer reaches the top edge, as IINA does.
- The window remains draggable by the top edge when chrome is hidden.

**Context menu**

With a selection: Look Up, Translate, Copy, Copy with Citation, Share, Search Book for “…”. Without a selection: Bookmark This Page, Show Contents. Use the WebKit defaults where they exist and add Platen's items alongside them.

**First-run explainer**

- The first time any book opens, overlay three translucent zones on the real page labelled "Back", "Show controls" and "Forward". Any click dismisses it.
- When the user switches between paginated and scroll mode, briefly flash the zone overlay for that mode (scroll mode shows a single "Show controls" zone). Do this for the first three switches only.
- Help > Show Reading Controls brings the explainer back at any time.
- The iOS version uses the same overlay, with the same zones.

## Bookmarks, page numbers and getting text out

Bookmarks are the only annotation feature; highlights and notes are deliberately excluded, and "Copy with Citation" lets readers keep notes in their own tools instead.

**Bookmarks**

- Add a bookmark by clicking the top-right corner of a page, pressing ⌘D, or choosing Bookmark This Page from the menu bar or context menu.
- A bookmarked page shows a small ribbon graphic in its top-right corner. Clicking the ribbon removes the bookmark.
- When the pointer hovers over the top-right corner of an unbookmarked page, show a faint ribbon outline so the feature can be discovered.
- A bookmark is anchored to the CFI of the first word on the page. After resizing, the ribbon appears on whichever page now contains that word.
- In a two-page spread, each page has its own corner and its own bookmark.
- In scroll mode, a bookmark anchors to the first word visible at the top of the window, and the ribbon is drawn at the right edge level with that line.
- The contents panel has a Bookmarks tab listing each bookmark with its chapter and the first line of text; selecting one jumps there (and shows the Back button).

**Location and page numbers**

- The primary location indicator is a percentage through the book plus the chapter name, which stay meaningful as the layout changes.
- When an EPUB 3 book includes a page list (the print edition's page numbers), show the printed page number ("p. 214") in the location line and in Copy with Citation. These never change with window size.
- Optionally, in the location line, show "N pages left in chapter" in paginated mode. Platen's own page counts are never presented as stable page numbers.

**Getting text out**

- **Copy with Citation** copies the selected text followed by a citation line: author, *title*, chapter, and printed page number where available. It writes both plain text and rich text to the pasteboard.
- **Share** uses the system share menu (Notes, Mail, Messages and so on).
- **Look Up** and **Translate** use the system services WebKit provides.
- **Find in book** (⌘F) searches the full text, lists results with surrounding context in the sidebar, and highlights matches temporarily.

## Typography and themes

The publisher's design is the default (but for line spacing, 1.5 unless the reader chooses Publisher); the reader can override body font, size, line spacing and line width, and choose one Appearance: Automatic (following the system's light and dark appearance) or one of four themes.

**Typography controls**

| Control | Default | Range |
| --- | --- | --- |
| Font | Publisher default | Publisher default, or an override from a short curated list plus any installed system font |
| Text size | A sensible default for the display (around 18 pt equivalent on a Retina laptop) | Stepped, about 12 steps; ⌘+ / ⌘− |
| Line spacing | 1.5 | Publisher, then 1.2 to 2.0 in steps. 1.5 rather than the publisher's (23 Nov 2026): most books leave it to the reading app, and their "normal" (about 1.2) is tight on a screen |
| Line width | Medium (about 66 characters) | Narrow, medium, wide (about 55, 66, 80 characters) |

- Line width replaces margins as the control. In paginated mode it caps column width; in scroll mode it sets the centred column width.
- A font override replaces the body text font only. It preserves italic and bold, keeps monospace for code, and leaves fonts alone where the book uses them for a specific script or purpose (for example non-Latin text, or a drop cap). Implement via injected CSS with carefully scoped selectors and `!important` only where needed, and test against the robustness corpus.
- On iOS, the default text size follows Dynamic Type. On macOS there is no reliable system text-size setting for third-party apps, so use the default above; the first change the user makes becomes the default.
- Hyphenation on by default in paginated mode, using the book's language.

**Themes**

| Theme | Page | Text |
| --- | --- | --- |
| Light | White | Near-black |
| Sepia | Warm cream | Dark brown |
| Dark | Near-black (not pure black) | Light grey |
| Black | True black, for OLED screens | A slightly dimmer grey |

- One Appearance setting: Automatic (the default), Light, Sepia, Dark or Black. Automatic uses Light in the system's Light appearance and Dark in its Dark appearance; with macOS appearance set to Auto, this switches at sunset without Platen needing location access.
- Themes recolour backgrounds and text, and leave images untouched. Images that are dark line art on transparent backgrounds get a light backing in the Dark theme so they stay legible.
- Publisher colours on text are preserved in Light, and softened in Sepia and Dark only where they would fail contrast.
- No in-app colour-temperature filter: Night Shift already provides it system-wide.

## Settings and file associations

All settings are global and live in Platen Reader > Settings… (⌘,), a standard tabbed macOS settings window; the only per-book data is reading position and bookmarks.

| Tab | Contents |
| --- | --- |
| Appearance | Text: font, text size, line spacing, hyphenation and Appearance (the Aa popover's controls). Layout: the layout new books open in, line width, page-turn animation (Page Curl, Slide or None), pages left in chapter (the Layout popover's controls) |
| File Types | One row per supported type with its current default app and a "Make Platen the default" button, plus "Make Platen the default for all" |
| Advanced | Clear reading positions and bookmarks; reveal the data folder in Finder; show the first-run tips again |

**File associations**

- Declare document types in the app's Info.plist: `.epub`, `.kepub.epub` (and `.kepub`), `.mobi`, `.azw`, `.azw3`. Use system UTIs where they exist (`org.idpf.epub-container`) and declare imported types for the rest.
- Set the default handler with `NSWorkspace.setDefaultApplication(at:toOpen:)` per content type. Read the current default with `NSWorkspace.urlForApplication(toOpen:)` to display it.
- iOS has no default-app mechanism for file types. There, Platen declares the same types so it appears in "Open in" and the share sheet, and its home screen is Platen's own (see "iOS and iPadOS").

**Per-book data**

- Stored in one JSON file per book in `~/Library/Application Support/Platen Reader/books/<book-key>.json`, where the key is derived from the OPF identifier and file fingerprint.
- Contents: schema version, book identifiers, last known file path (informational only), last CFI, bookmarks (CFI, created date, text snippet), and last-opened date.
- The format is human-readable and documented in the repository, but portability between apps is not a goal.

## iOS and iPadOS (M3)

The iOS app is the Mac reader on a touch screen: the same core, the same web shell, the same overlay and zones, with touch replacing the pointer. These decisions were settled on 11 Nov 2026.

**Opening books**

- Launching never lands in a file browser. If a book was open when the app was last left, it reopens at the same place. Otherwise (the book was closed with its Close button, or none was open) the home screen shows the folder view, or, before a folder is chosen, the Mac's welcome screen, full screen: the app's name, "Open Book…", "Choose Folder…" and the formats it reads; "Open Book…" shows the system's document picker. A book opened from another app goes straight to that book.
- The home screen is Platen's own view controller, not the system document browser; it decides what launch shows and presents the readers. A folder chosen with "Choose Folder…" (kept as a security-scoped bookmark, because opening one book gives no access to its folder) joins Recent Folders and opens there as a grid of large covers, about three across on an iPhone, with the folders inside it first. Covers come from PlatenCore (`BookCover`: EPUB covers, a PDF's first page; MOBI and AZW3 later) and are cached in Caches; books without one get a plain cover with their title. Books still in iCloud show a placeholder and download when tapped, then open. Books added or removed appear and go without a refresh. A book left open still reopens directly at launch. The home screen has three tabs, their bar always on screen: Home (the welcome for now: Open Book…, Choose Folder…), Recent Books (covers of books opened lately, from anywhere; one that cannot be reached is greyed and marked) and Recent Folders (a list, with where each is kept and its path; folders open inside the tab). A long press removes an item from a recents list; + in each adds a book or folder. A folder can be searched by file name, title and author, and filtered by kind of book. Books are opened in place (`LSSupportsOpeningDocumentsInPlace`), from Files, iCloud Drive, SMB shares or any file provider, through security-scoped URLs. They are never copied into the app; "Open in Platen" from another app also opens in place where the provider allows it.
- Book identity does not depend on the path, so positions and bookmarks work as on the Mac.
- All Mac formats are supported from 1.0: EPUB 2 and 3, KEPUB, MOBI, AZW, AZW3.

**Touch**

| Input | Paginated | Scroll |
| --- | --- | --- |
| Tap, left third | Previous page | Toggle overlay |
| Tap, centre third | Toggle overlay | Toggle overlay |
| Tap, right third | Next page | Toggle overlay |
| Tap in the top-right corner of a page | Add or remove bookmark | Add or remove bookmark |
| Tap on a link | Follow link | Follow link |
| Horizontal swipe | Turn page, tracking the finger | (none) |
| Long press, drag handles | Select text | Select text |
| Tap a picture | Zoom it | Zoom it |

- **Page turns:** a swipe uses the page-turn animation chosen in Settings (Page Curl, Slide or None), tracking the finger in every case. On touch the swipe is the primary way to turn pages, so unlike the Mac trackpad (which always slides) there is no override.
- **Bookmarks:** there is no hover on touch to reveal the faint ribbon outline in the top-right corner; the overlay's Bookmark button does that job.
- **Selection menu:** the system edit menu gains Copy with Citation, Search Book for "…" and Share, alongside Copy, Look Up and Translate.
- **Hardware keyboard (iPad and iPhone):** the Mac shortcuts apply, listed in the iPad ⌘ shortcut overlay.

**Layout**

- Two pages side by side on iPad in landscape only. iPhone (either orientation) and iPad in portrait show one page. Split View and Slide Over use the window width as on the Mac.
- The status bar and home indicator hide with the overlay.
- **Overlay:** the Mac bar's controls, arranged as Apple's own iOS 26 apps arrange theirs, as small pieces of glass floating over the page with no panel behind them. Top left: a round Close button, then the title and chapter, with the width of the screen to themselves. Bottom right, just above the slider and within reach of a thumb: Contents, Bookmark, Layout, Aa and Settings in one group; each opens a popover (Settings too, not a sheet). Bottom: the progress slider (on no glass of its own) between round ‹ and › buttons, and the location line in small text below it, in place of the page number. Over PDFs the controls are always light, since the pages are white in every theme.
- **Start and end:** a turn or swipe past the first or last page shows a short notice ("Start of book", "End of book") in the middle of the page, read out by VoiceOver.
- Default text size follows Dynamic Type.

**Settings**

- In the app, not in the system Settings app: the Aa and Layout popovers as on the Mac, plus a settings sheet with the General and Appearance options and Clear reading positions and bookmarks. The File Types tab has no iOS counterpart.

**Mac App Store build** (after launch; not part of 1.0)

- Same bundle ID as iOS and the direct-download build. It is sandboxed, so check before release: whether `NSWorkspace.setDefaultApplication` works from the sandbox (if not, the File Types tab shows the current default and explains how to change it in Finder's Get Info); that per-book data moves into the container, with a container migration so existing direct-download users keep their positions; and that SMB and iCloud opens, Open Recent and window restoration work under the sandbox.

**Testing and performance**

- Main test device: iPhone 15 Pro Max. Also an iPad Pro, for two-page layout, Split View and the hardware keyboard. The Simulator is for everything else.
- The performance targets above apply, measured on the iPhone 15 Pro Max ("window resize" means rotation or a Split View change).

**Still needed before submission**

- Support URL (required by App Store Connect) and a privacy policy URL (it only needs to say that nothing is collected).
- Screenshots for iPhone, iPad and Mac.
- App Store signing: an Apple Distribution certificate and provisioning profiles for Mac and iOS, or automatic signing, and whether CI uploads builds to TestFlight. This is being set up separately.

## PDF

PDFs open in the same window and overlay as books, rendered by PDFKit (`PDFView`) on both platforms. Platen adds its interaction model and stays out of the way; it does not edit or annotate PDFs.

- **Interaction:** the same click (or tap) zones, centre overlay and click-drag selection. Look Up, Copy and Share work on selected text.
- **Position:** reopens at the last page and zoom, stored in the per-book data. A PDF is identified by the same fingerprint as a book (file size plus a hash of the first and last 64 KB), with the PDF's document ID in place of the OPF identifier.
- **Contents:** the PDF outline in the Contents tab; bookmarks and search work as for books, anchored to page numbers instead of CFIs.
- **Layout on the Mac:** the Layout setting maps to PDFKit's display modes. One Page is single page, Two Pages is two-up, Scroll is continuous.
- **Layout on iPhone and iPad:** the Layout button offers One Page, Two Pages and Scroll (the same settings as for books), as a list with a tick by the one in use. Scroll is one continuous column of pages. One Page shows one page at a time in either orientation, fitted to the screen (PDFs of picture books may have landscape pages, or portrait ones). Two Pages shows one page in portrait; in landscape, the current page and the next one side by side, touching (only when the pages are taller than wide or about square: a PDF whose pages are already spreads, clearly wider than tall, shows one at a time), so a scanned two-page spread reads as one (the Layout popover says so while in portrait). This applies to iPhone as well as iPad, unlike EPUB, where iPhone always shows one page.
- **Pictures:** a long press on a picture in a PDF offers Save to Photos, Save to Files and Share. The picture is found from the page's drawing instructions (PlatenCore's `PDFPictures`) and drawn from the page at up to about 300 dots per inch. Save to Photos asks once for add-only access to the photo library, the one permission prompt in the app, and only when the reader chooses it.
- **Spread pairing is the reader's choice, by rotating.** PDFs of books pair their pages inconsistently: some have the cover alone and then left-right spreads, and some have a second cover page first, which shifts every pair by one. Platen does not guess. Rotating to landscape shows the page the reader was on plus the next one, and that pairing holds: each turn in landscape moves two pages. If the pairs look wrong, the reader rotates back to portrait, turns one page and rotates again. Rotating back to portrait shows the left page of the pair.
- **Controls:** EPUB-only controls (font, text size, line spacing, line width) are hidden for PDFs. Themes colour only the background around the page; an optional inverted-colour night mode may follow.
- **Ambient background (iOS; the Mac may follow):** the background around the pages takes their colours, softened and blurred, as an Ambilight television lights the wall behind it. Each colour keeps its hue but is brought towards the theme's brightness, so white paper stays close to the theme and only coloured pages glow. It is made from a tiny drawing of the pages on screen, off the main thread, and fades over when the page changes, so it never slows reading.
- **Page Curl:** only the page (or spread) curls, not the background around it; the back of the leaf is paper white.
- **File association:** `com.adobe.pdf` is listed in File Types, but Platen is never made the default for PDFs unless the user chooses it.

## Format support and robustness

Opening odd and broken files gracefully is the product's main quality bar; every case below needs a fixture in the test corpus and a passing test before milestone 1 ships.

| Case | Required behaviour |
| --- | --- |
| EPUB 2 with NCX table of contents | Contents built from the NCX |
| EPUB 3 with navigation document | Contents built from the nav document; page list and landmarks read when present |
| No table of contents at all | Contents synthesised from spine items and their first headings |
| Malformed XHTML (unclosed tags, bad entities) | WebKit's strict XML parser shows an error page, so detect parse failure and re-serve the document as `text/html` for lenient parsing |
| Path case mismatches (`Chapter1.xhtml` vs `chapter1.xhtml`) | Case-insensitive fallback lookup in the zip |
| Percent-encoded or Unicode file names in hrefs | Normalised before lookup |
| Obfuscated fonts, IDPF scheme | De-obfuscated on load (XOR the first 1040 bytes with a SHA-1 key from the unique identifier) |
| Obfuscated fonts, Adobe scheme | De-obfuscated on load (XOR the first 1024 bytes with a key from the UUID identifier) |
| Fixed layout (`rendition:layout pre-paginated`) | Rendered per Reading modes and layout, honouring page-spread properties |
| Right-to-left books (Arabic, Hebrew; `page-progression-direction rtl`) | Page turns and click zones reverse |
| Vertical writing (Japanese, Chinese) | Rendered vertically with correct page progression |
| MathML and SVG content | Rendered natively by WebKit |
| Audio and video elements | Play inline with standard controls |
| Scripted content | JavaScript in book content disabled by default (see Architecture) |
| Media overlays (read-aloud sync) | Ignored in milestone 1; text still displays |
| Calibre output quirks (`calibre:` metadata, split files) | Opens normally |
| KEPUB (Kobo spans and `koboSpan` markup) | Opens as EPUB; Kobo-specific styling neutralised where it breaks layout |
| MOBI and AZW3, DRM-free | Opened via foliate-js's MOBI/KF8 support |
| Plain text (.txt) | Shown as a book: UTF-8 or UTF-16, else Windows-1252; hard-wrapped paragraphs joined, other line breaks (poetry, lists) kept; headings such as "Chapter 1" become Contents and sections; title and author from a Gutenberg-style header, else the file name. With no publisher design, "Publisher Default" means a book serif (Iowan Old Style) and 1.5 line spacing. Listed in File Types but never made the default unless chosen |
| KFX | Unsupported; clear message |
| DRM: Adobe ADEPT, Apple FairPlay, Readium LCP, Kindle | Detected; plain message naming the DRM type |
| Zip problems (wrong `mimetype` position, extra data, Zip64) | Tolerated where the content is still readable |
| Very large books (300 MB illustrated) | Lazy entry loading; no full read into memory |
| Corrupt or truncated zip | Opens what can be read, reports the rest |
| MOBI (MOBI 6) with a picture | Text and picture shown |
| AZW3 (KF8) whose pictures keep the EPUB's `srcset` (as Standard Ebooks' do) | Pictures shown: the srcset's file paths, which a KF8 book does not have, are ignored |
| PDF read aloud, with running headers, footers and page numbers | Read as a reader would: headers, footers and page numbers left out, words hyphenated across lines joined, sentences across pages read whole |

**Test corpus**

Build it at the start of milestone 1 and grow it with every bug report: Standard Ebooks and Project Gutenberg files (EPUB 2 and 3), Calibre conversions, Kobo store-style KEPUBs, fixed-layout picture books and comics, RTL and vertical samples, the EPUB 3 test suite from the W3C, and deliberately broken files generated by a script. Standard Ebooks files double as a regression test for "show the book as published": watch justification and `text-wrap: pretty`, which their CSS uses. Only include files that may legally be redistributed; keep others in a local, git-ignored folder.

## Architecture

Platen is a native Swift app with a thin platform layer over a shared core package; WebKit and foliate-js do the rendering, and Swift owns everything about files, parsing and state.

&#91;embedded content: Platen architecture · apps, shared core, reader view\]

Book bytes flow down from the core into the web view through a custom URL scheme; positions and user events flow back up through a message bridge.

**Components**

- **Repository layout.** One Xcode project with a `PlatenCore` Swift package (platform-neutral, unit-tested), a macOS app target, and later an iOS app target. foliate-js is vendored at a pinned commit under `Resources/foliate`, with a short note on how to update it.
- **Book loader.** Reads the file through `NSFileCoordinator` (so iCloud downloads and coordinated access work), into memory below 50 MB, otherwise via a seekable handle with lazy zip entry reads. Uses a small, well-tested zip reader that supports Zip64; no extraction to disk.
- **Package parser.** Parses `container.xml`, the OPF (metadata, manifest, spine, rendition properties), NCX or nav document, page list and landmarks. Lenient by design: logs problems and continues.
- **Fixups.** Font de-obfuscation, case-insensitive and percent-decoded path resolution, and the XHTML-to-HTML fallback for malformed documents.
- **Position store.** Reads and writes the per-book JSON files. Writes are atomic and debounced.
- **Reader view.** A `WKWebView` that loads a small local HTML shell containing foliate-js. A `WKURLSchemeHandler` for `platen://` serves book resources from the loader with correct MIME types. A `WKScriptMessageHandler` bridge carries events (location changed, click zone, selection, link followed) to Swift and commands (go to CFI, set theme, set typography) from Swift.
- **Content security.** Book content runs in sandboxed iframes with scripts disabled. Remote network loads are blocked with a `WKContentRuleList`. The web view has no access to the file system beyond the scheme handler.
- **Platform layer (macOS).** `NSDocument`-based app (SwiftUI where it helps, AppKit where control is needed: window chrome, menus, gesture tracking). Owns the overlay, click-zone hit testing, menus and shortcuts, Settings, and file associations.

**Engineering practices**

- Code is commented liberally, explaining what each part does and why, so a non-specialist can follow it.
- Unit tests for every parser and fixup against the corpus; UI tests for open, page turn, mode switch and bookmark flows; timing tests for the performance targets.
- CI on GitHub Actions builds, tests and produces a signed, notarised build for tagged releases.
- A `CLAUDE.md` at the repository root summarises this spec, the build and test commands, and the rule that the robustness corpus must stay green.

## Performance, accessibility, privacy and localisation

The measurable targets are opening speed and page-turn smoothness; accessibility and privacy are release requirements, not later polish.

**Performance targets** (measured on an M1 MacBook Air, typical 2 MB novel)

| Measure | Target |
| --- | --- |
| Warm open, local file, to text visible | Under 400 ms |
| Cold launch plus open, local file | Under 1 s |
| Open from SMB share on a gigabit LAN | Under 1 s |
| Page turn | Every frame at display refresh rate; no dropped frames during swipe tracking |
| Re-pagination after a window resize ends | Under 150 ms |
| Memory for a typical novel | Under 250 MB including the web content process |

Warm the WebKit content process at launch so the first open does not pay for it. Add automated timing tests for open and re-pagination so regressions show up in CI.

**Accessibility**

- Full VoiceOver support: the book text is read as text through WebKit's accessibility tree; overlay controls, contents, bookmarks and settings are labelled.
- Every function reachable by keyboard alone, including the overlay and the contents panel.
- Respect Reduce Motion, Increase Contrast and Reduce Transparency.
- Click zones and the overlay must not trap VoiceOver focus.

**Privacy**

- No analytics, telemetry or crash reporting that phones home. Crash logs stay with the system's own reporter.
- No network access at all, with two exceptions: the direct-download Mac build checks for updates through Sparkle (see Decisions made), and read aloud's natural voice is downloaded once, only when the reader asks for it: a dialog says in plain words what will be downloaded and how big it is, the reader agrees, and a progress sheet (with Cancel) shows the download. Nothing about the reader is sent. Agreed 22 Nov 2026. Remote resources in books are blocked.
- No location, contacts or other permission prompts.

**Localisation**

English at launch. All user-facing strings in String Catalogs from day one, with British English as the development language.

## Milestones

Five milestones, each with a clear exit test; the first is a short technical spike to retire the biggest risks before any UI polish.

**Launch (1.0)** is M1, M3 and M4 together: the Mac app (EPUB and PDF) as a notarised DMG with Sparkle updates, and the iOS and iPadOS app (EPUB and PDF) on the App Store. M2 and the Mac App Store build follow after launch.

1. **M0: Spike (risk retirement).** A bare document-based Mac app that opens an EPUB from disk and from an SMB share, renders it through foliate-js in WKWebView via a custom scheme handler, and turns pages.
   - Exit: warm open under 400 ms for a typical novel; malformed XHTML falls back to HTML parsing; two-finger swipe tracks the finger in a prototype; obfuscated fonts render.
2. **M1: Platen Reader for Mac 1.0.** Everything in this spec for macOS except the items listed under later milestones. PDF is M4, which also ships in 1.0.
   - Includes: paginated and scroll modes, automatic one or two pages, overlay, click zones, keyboard, first-run explainer, bookmarks, contents and search, Copy with Citation, typography, themes with system-appearance switching, Settings with file associations, MOBI/AZW3/KEPUB, robustness corpus green, VoiceOver.
   - Exit: all performance targets met; full corpus passes; notarised DMG on GitHub releases, updating through Sparkle, with a Homebrew cask.
3. **M2: Mac refinements.** A visual typography control (live preview instead of numeric steps), custom themes with a contrast warning, a Quick Look extension so the space bar previews EPUBs in Finder. After launch.
4. **M3: Platen Reader for iOS and iPadOS.** Same core package; touch interaction (tap zones identical to Mac, swipe page turns), Dynamic Type default size, a home screen of its own with the system document picker, iPad split view and hardware keyboard support, all formats including PDF. Ships on the App Store at launch; the Mac App Store build joins the same listing later. Details in "iOS and iPadOS (M3)".
5. **M4: PDF (in the launch scope).** PDFKit-backed view inside the same window and overlay on both platforms. Details in "PDF".

## Out of scope and parked ideas

These are deliberately excluded to keep Platen a viewer rather than a reading platform; revisit only with evidence of demand.

| Item | Status | Reason |
| --- | --- | --- |
| Library, bookshelf, collections, import | Out of scope | Folders are the library |
| Highlights and notes | Later | No cross-app standard for EPUB annotations, so they would create lock-in. If added: stored outside the book, keyed by book identity, with export to Markdown. Copy with Citation covers the need until then |
| Sync of positions or bookmarks between devices | Later, if at all | Possible through iCloud key-value storage keyed by book identity, with no account; reconsider after iOS ships |
| In-app colour-temperature (warm after sunset) | Rejected | Night Shift already does this system-wide; theme scheduling covers the rest |
| Text selection mode | Rejected | Click-drag selects text natively |
| DRM removal or DRM-protected playback | Out of scope | Legal and licensing reasons |
| KFX format | Out of scope | Proprietary and poorly documented |
| Read-aloud sync with a book's own recorded narration (EPUB media overlays) | Parked | Read aloud with synthetic voices is decided (see Decisions made); playing a book's own audio in step with its text is not |
| Natural read-aloud voice (Kokoro-82M, downloaded on request) | Under way, 22 Nov 2026 | First built on ONNX Runtime and parked: it added about 40 MB to every install and sent Microsoft telemetry unless switched off. Now runs on our own Swift code on Accelerate, with no runtime (nothing that could send telemetry, no larger app for those who do not use it), as an 82 MB English download. Its download is an agreed network exception (see Privacy: only on the reader's explicit request). Its download comes from a GitHub release at launch (decided 23 Nov 2026), checked against a pinned SHA-256, on Mac and every supported iOS. See docs/read-aloud.md |
| Custom themes | Parked to M2 |  |
| Visual typography control | Parked to M2 |  |
| In-app book list, OPDS catalogues, downloading books | Out of scope | Platen shows files the user already has; a catalogue is a library and needs the network |
| Mac App Store build | After launch | See "iOS and iPadOS (M3)" |
| A second source for the voice download | After launch | At launch the natural voice comes from a GitHub release, checked against a pinned SHA-256; a second host (Cloudflare R2, Backblaze B2 or similar) as a fallback comes after. See docs/read-aloud.md, "Hosting the voice" |
| CBZ comics | Parked | foliate-js supports it, so it may come almost free; decide after M1 |

## To be decided

Ideas worth keeping that need more thought before they are planned.

- **Bundled first book.** Ship one public-domain Standard Ebooks title so the first launch opens straight into a book instead of the welcome window. Note that "Platen ships no content" is part of the case for the 4+ age rating.
- **Stable computed page numbers.** For books without a page list, a computed count that does not change with the window, shown as "page X of Y", and an estimate of time left in the chapter. Risks being complex, and the spec currently says Platen's own page counts are never presented as stable.
