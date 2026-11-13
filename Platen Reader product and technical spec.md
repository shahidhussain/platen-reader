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
| Language | English at launch, all strings localisable |  |

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
- Help > Send Feedback… opens a blank email to the same address with the app version and OS in the subject tag. Nothing is sent without the user pressing Send.

## Reading modes and layout

Reflowable books have two modes, paginated (the default) and continuous scroll; fixed-layout books are always paginated.

**Paginated (default)**

- Text is laid out in pages that turn left and right, like a book.
- Page or spread count is decided by window width, as in Apple Books. In Automatic mode, Platen shows two pages side by side whenever each column can hold a comfortable line length (roughly 50 or more characters at the current font size), otherwise one. The user can force one or two pages from the View menu.
- In full screen on a typical Mac display this nearly always produces a two-page spread.
- Page turns animate with a short horizontal slide of 150 to 200 ms. No animation when the system Reduce Motion setting is on. No page-curl effect.
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

The publisher's design is the default; the reader can override body font, size, line spacing and line width, and choose one of three themes that can follow the system's light and dark appearance.

**Typography controls**

| Control | Default | Range |
| --- | --- | --- |
| Font | Publisher default | Publisher default, or an override from a short curated list plus any installed system font |
| Text size | A sensible default for the display (around 18 pt equivalent on a Retina laptop) | Stepped, about 12 steps; ⌘+ / ⌘− |
| Line spacing | Publisher default | Publisher, then 1.2 to 2.0 in steps |
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

- Setting "Follow system appearance" (on by default): choose one theme for Light appearance and one for Dark. With macOS appearance set to Auto, this switches at sunset without Platen needing location access.
- Themes recolour backgrounds and text, and leave images untouched. Images that are dark line art on transparent backgrounds get a light backing in the Dark theme so they stay legible.
- Publisher colours on text are preserved in Light, and softened in Sepia and Dark only where they would fail contrast.
- No in-app colour-temperature filter: Night Shift already provides it system-wide.

## Settings and file associations

All settings are global and live in Platen Reader > Settings… (⌘,), a standard tabbed macOS settings window; the only per-book data is reading position and bookmarks.

| Tab | Contents |
| --- | --- |
| General | Default reading mode (paginated or scroll); page layout (automatic, one page, two pages); page-turn animation on or off; reset first-run tips |
| Appearance | Follow system appearance, with a theme for Light and one for Dark; default font, text size, line spacing, line width (the same controls as the Aa popover) |
| File Types | One row per supported type with its current default app and a "Make Platen the default" button, plus "Make Platen the default for all" |
| Advanced | Clear reading positions and bookmarks; reveal the data folder in Finder |

**File associations**

- Declare document types in the app's Info.plist: `.epub`, `.kepub.epub` (and `.kepub`), `.mobi`, `.azw`, `.azw3`. Use system UTIs where they exist (`org.idpf.epub-container`) and declare imported types for the rest.
- Set the default handler with `NSWorkspace.setDefaultApplication(at:toOpen:)` per content type. Read the current default with `NSWorkspace.urlForApplication(toOpen:)` to display it.
- iOS has no default-app mechanism for file types. There, Platen declares the same types so it appears in "Open in" and the share sheet, and its home screen is the system document browser (see "iOS and iPadOS").

**Per-book data**

- Stored in one JSON file per book in `~/Library/Application Support/Platen Reader/books/<book-key>.json`, where the key is derived from the OPF identifier and file fingerprint.
- Contents: schema version, book identifiers, last known file path (informational only), last CFI, reading mode at close, bookmarks (CFI, created date, text snippet), and last-opened date.
- The format is human-readable and documented in the repository, but portability between apps is not a goal.

## iOS and iPadOS (M3)

The iOS app is the Mac reader on a touch screen: the same core, the same web shell, the same overlay and zones, with touch replacing the pointer. These decisions were settled on 11 Nov 2026.

**Opening books**

- The home screen is the system document browser. Books are opened in place (`LSSupportsOpeningDocumentsInPlace`), from Files, iCloud Drive, SMB shares or any file provider, through security-scoped URLs. They are never copied into the app; "Open in Platen" from another app also opens in place where the provider allows it.
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
- **Bookmarks:** there is no hover on touch, so the faint ribbon outline in the top-right corner shows while the overlay is up.
- **Selection menu:** the system edit menu gains Copy with Citation, Search Book for "…" and Share, alongside Copy, Look Up and Translate.
- **Hardware keyboard (iPad and iPhone):** the Mac shortcuts apply, listed in the iPad ⌘ shortcut overlay.

**Layout**

- Two pages side by side on iPad in landscape only. iPhone (either orientation) and iPad in portrait show one page. Split View and Slide Over use the window width as on the Mac.
- The status bar and home indicator hide with the overlay.
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
- **Layout on iPhone and iPad:** follows orientation. Portrait shows one page at a time. Landscape shows the current page and the next one side by side, touching, so a scanned two-page spread reads as one. This applies to iPhone as well as iPad, unlike EPUB, where iPhone always shows one page.
- **Spread pairing is the reader's choice, by rotating.** PDFs of books pair their pages inconsistently: some have the cover alone and then left-right spreads, and some have a second cover page first, which shifts every pair by one. Platen does not guess. Rotating to landscape shows the page the reader was on plus the next one, and that pairing holds: each turn in landscape moves two pages. If the pairs look wrong, the reader rotates back to portrait, turns one page and rotates again. Rotating back to portrait shows the left page of the pair.
- **Controls:** EPUB-only controls (font, text size, line spacing, line width) are hidden for PDFs. Themes colour only the background around the page; an optional inverted-colour night mode may follow.
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
- No network access at all, with one exception: the direct-download Mac build checks for updates through Sparkle (see Decisions made). Remote resources in books are blocked.
- No location, contacts or other permission prompts.

**Localisation**

English at launch. All user-facing strings in String Catalogs from day one, with British English as the development language.

## Milestones

Five milestones, each with a clear exit test; the first is a short technical spike to retire the biggest risks before any UI polish.

**Launch (1.0)** is M1, M3 and M4 together: the Mac app (EPUB and PDF) as a notarised DMG with Sparkle updates, and the iOS and iPadOS app (EPUB and PDF) on the App Store. M2 and the Mac App Store build follow after launch.

1. **M0: Spike (risk retirement).** A bare document-based Mac app that opens an EPUB from disk and from an SMB share, renders it through foliate-js in WKWebView via a custom scheme handler, and turns pages.
   - Exit: warm open under 400 ms for a typical novel; malformed XHTML falls back to HTML parsing; two-finger swipe tracks the finger in a prototype; obfuscated fonts render.
2. **M1: Platen Reader for Mac 1.0.** Everything in this spec for macOS except the items listed under later milestones. PDF is M4, which also ships in 1.0.
   - Includes: paginated and scroll modes, automatic one or two pages, overlay, click zones, keyboard, first-run explainer, bookmarks, contents and search, Copy with Citation, typography, three themes with system-appearance switching, Settings with file associations, MOBI/AZW3/KEPUB, robustness corpus green, VoiceOver.
   - Exit: all performance targets met; full corpus passes; notarised DMG on GitHub releases, updating through Sparkle, with a Homebrew cask.
3. **M2: Mac refinements.** A visual typography control (live preview instead of numeric steps), custom themes with a contrast warning, a Quick Look extension so the space bar previews EPUBs in Finder. After launch.
4. **M3: Platen Reader for iOS and iPadOS.** Same core package; touch interaction (tap zones identical to Mac, swipe page turns), Dynamic Type default size, system document browser as the home screen, iPad split view and hardware keyboard support, all formats including PDF. Ships on the App Store at launch; the Mac App Store build joins the same listing later. Details in "iOS and iPadOS (M3)".
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
| Text-to-speech, read-aloud sync | Parked | Possible later via system speech, highlighting the sentence being read |
| Custom themes | Parked to M2 |  |
| Visual typography control | Parked to M2 |  |
| In-app book list, OPDS catalogues, downloading books | Out of scope | Platen shows files the user already has; a catalogue is a library and needs the network |
| Mac App Store build | After launch | See "iOS and iPadOS (M3)" |
| CBZ comics | Parked | foliate-js supports it, so it may come almost free; decide after M1 |

## To be decided

Ideas worth keeping that need more thought before they are planned.

- **Bundled first book.** Ship one public-domain Standard Ebooks title so the first launch opens straight into a book instead of the welcome window. Note that "Platen ships no content" is part of the case for the 4+ age rating.
- **Stable computed page numbers.** For books without a page list, a computed count that does not change with the window, shown as "page X of Y", and an estimate of time left in the chapter. Risks being complex, and the spec currently says Platen's own page counts are never presented as stable.
