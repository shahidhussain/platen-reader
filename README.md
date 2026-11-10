# Platen Reader

A free, open source ebook viewer for macOS that behaves like Preview: double-click a book and you are reading it within a second. There is no library, no import step and no account. It reads EPUB 2 and 3 (reflowable and fixed layout), KEPUB, MOBI and AZW3, all DRM-free.

Platen is native Swift. Rendering uses [foliate-js](https://github.com/johnfactotum/foliate-js) inside WKWebView, and Swift handles everything about files, parsing and state.

## Building

You need Xcode 16 or later and macOS 14 or later.

1. Open `PlatenReader.xcodeproj` and run the **PlatenReader** scheme.
2. Use File > Open… to open a book, or generate test books with `python3 scripts/make-fixtures.py` and open one from `Fixtures/generated/`.

To run the core tests: `swift test --package-path PlatenCore`. To check the robustness corpus against a Debug build: `python3 scripts/make-fixtures.py && scripts/check-corpus.sh`.

## Status: M1 in progress

**Done in M0 (spike):**

- A document-based app with one window per book. Open Recent, tabs and window restoration come from the system.
- Books are read into memory in one read (up to 50 MB) or lazily through a file handle, then served to the web view through `platen://` with no extraction to disk.
- Paginated mode with automatic, one-page or two-page layout, plus continuous scroll. Fixed-layout books always paginate.
- Click zones, keys, trackpad swipe tracking, and the overlay with its slider and Aa popover.
- Reading position saved as a CFI and restored on open; themes following the system appearance; Settings.
- Robustness: malformed XHTML, path mismatches, font de-obfuscation, Zip64 and damaged zips, DRM and KFX messages. Book scripts and remote loads are blocked.

**Done so far in M1:**

- **Contents panel (⌘T)** with Contents, Bookmarks and Search tabs. The current chapter is highlighted. Books with no table of contents get one built from their headings.
- **Bookmarks:** ⌘D, a click in a page's top-right corner, or the context menu. A red ribbon marks the page and a faint outline appears on hover. Each page of a two-page spread has its own corner, and fixed-layout pages work too. Bookmarks are listed with chapter, printed page and first line.
- **Find in book (⌘F, ⌘G, ⇧⌘G, ⌘E):** results are grouped by chapter with the match in context, and matches are highlighted on the page until the panel closes.
- **Back button:** "Back to p. 87" or "Back to Chapter 3" after any jump (contents, link, bookmark, search, slider), kept until the reader turns a page. Also ⌘[.
- **Copy with Citation (⇧⌘C):** the quote, then author, *title*, chapter and printed page, as plain and rich text. Share Selection…; context-menu items (Copy with Citation, Search Book for "…", Bookmark This Page, Show Contents), with browser-only items removed.
- **Click-zone explainer** on the first five opens, flashed on the first three mode switches, and from Help > Show Reading Controls.
- The slider shows the chapter name while dragging. "N pages left in chapter" is optional, in Settings > General.
- Page turns animate in 180 ms. KEPUB column wrappers are neutralised.
- **Trackpad swipes** are read natively (finger phases, momentum ignored): the page follows the fingers, a flick or a drag past halfway turns one page, and anything less springs back. A mouse wheel turns one page per notch.
- **Page numbers** centred under each page (one per page in a two-page spread). They are screen pages and move with the text.
- **Page-turn animation** (Settings > General: Page Curl, Slide or None; trackpad swipes always slide), drawn natively from before-and-after snapshots. With two pages the leaf bends like paper (a chain of hinged strips), is shaded by its angle and casts a shadow on the pages beneath.
- **No blank pages between chapters:** the old page stays on screen until the next chapter is laid out (a small foliate-js patch).
- **Readable colours:** publisher text colours with too little contrast against the theme are replaced by the theme's text colour.
- **Pictures:** click one to zoom it to fill the window; right-click for Copy Image, Save Image… and Share….
- **Publisher sizes in px, pt or keywords** are rewritten to rem so the text size setting works on every book. Over-wide tables and blocks are kept inside the page.
- The title bar floats over the page, so showing the controls no longer re-flows the text. The controls stay up while the Aa popover is open. C shows and hides them.
- One **Appearance** setting: Automatic, Light, Sepia, Dark or Black (for OLED screens).
- One **Layout** setting: One Page (⌘1), Two Pages (⌘2) or Scroll (⌘3). Layout and line width have their own popover in the controls; Aa holds text and appearance.
- Contents, bookmarks and search open in a popover from the Contents button. A bookmark button sits in the controls.
- A welcome window with an Open Book… button at launch; one running copy of the app; ⌘W closes the front window whatever has focus.
- The click-zone explainer shows for the first five books opened. A note explains when Two Pages shows one page because the window is narrow.
- `scripts/check-corpus.sh` opens every fixture and checks the result (16 of 16 pass). Core timing tests and a GitHub Actions workflow are in place.

Measured here (Debug build, cold launch plus open): about 290 ms to the first visible page for a 2 MB novel.

## Not yet done

- **Checked only by script so far:** real mouse, keyboard and trackpad input (clicks in corners, hover outline, context menu, swipe feel) and VoiceOver. Needs a pass by hand.
- **Formats and sources:** MOBI and AZW3 with real DRM-free samples; SMB and iCloud-offloaded opens; the real-world corpus (Standard Ebooks, Gutenberg, the W3C EPUB 3 tests).
- **UI:** top-edge reveal in full screen; publisher colours softened only where they fail contrast in Sepia and Dark; a font picker listing all installed fonts.
- **Testing:** XCUITests for open, page turn, mode switch and bookmarks, and running the corpus check in CI.
- **Releasing:** a notarised build on GitHub releases and a Homebrew cask. These need a Developer ID certificate and App Store Connect API key, held as repository secrets.

## Licence

[Mozilla Public License 2.0](LICENSE). foliate-js is MIT-licensed; see `PlatenReader/Web/foliate/LICENSE`.
