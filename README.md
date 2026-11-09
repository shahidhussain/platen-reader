# Platen Reader

A free, open source ebook viewer for macOS that behaves like Preview: double-click a book and you are reading it within a second. There is no library, no import step and no account. It reads EPUB 2 and 3 (reflowable and fixed layout), KEPUB, MOBI and AZW3, all DRM-free.

Platen is native Swift. Rendering uses [foliate-js](https://github.com/johnfactotum/foliate-js) inside WKWebView, and Swift handles everything about files, parsing and state.

## Building

You need Xcode 16 or later and macOS 14 or later.

1. Open `PlatenReader.xcodeproj` and run the **PlatenReader** scheme.
2. Use File > Open… to open a book, or generate test books with `python3 scripts/make-fixtures.py` and open one from `Fixtures/generated/`.

To run the core tests: `swift test --package-path PlatenCore`.

## Status: M0 (spike) complete

What works:

- A document-based app with one window per book. Open Recent, tabs and window restoration come from the system.
- Books are read into memory in one read (up to 50 MB) or lazily through a file handle, then served to the web view through `platen://` with no extraction to disk.
- Paginated mode with automatic, one-page or two-page layout, plus continuous scroll. Fixed-layout books always paginate.
- Click zones (back, show controls, forward). Keys: ← → Space PgUp PgDn, ⌘← ⌘→ for chapters, ⌘[ for back, ⌘+ ⌘− ⌘0 for text size, Esc.
- A trackpad horizontal swipe tracks the fingers and snaps to a page. A vertical wheel turns one page per gesture.
- Reading position is saved as a CFI, keyed by OPF identifier plus file fingerprint, and restored on open. A book with no saved position opens at the start of the main text.
- Overlay: the title bar fades in, plus a bottom bar with the location line, a progress slider with chapter ticks, page buttons and an Aa popover.
- Light, Sepia and Dark themes, following the system appearance. Font, size, line spacing and line width are adjustable.
- Settings: General, Appearance, File Types (make Platen the default) and Advanced.
- Robustness:
  - Malformed XHTML falls back to HTML parsing.
  - Path case and percent or Unicode mismatches are resolved.
  - IDPF and Adobe font de-obfuscation.
  - Zip64, prefixed data and truncated zips; a missing package file is rebuilt from the surviving chapters.
  - ADEPT, FairPlay, LCP and Kindle DRM, and KFX files, get a plain message.
- Security: book scripts are disabled and remote loads are blocked.

Measured on this machine (Debug build, cold launch plus open): about 270 ms to the first visible page for a 2 MB novel, and about 175 ms for small books.

## Not yet done (M1)

- Contents and bookmarks sidebar (⌘T), bookmarks with the corner ribbon (⌘D), and Find in book (⌘F/⌘G).
- Copy with Citation, Share and the custom context-menu items.
- First-run click-zone explainer (for now the overlay is shown once instead), and Help > Show Reading Controls.
- Back button in the overlay, slider chapter labels while dragging, and "pages left in chapter".
- Hover ribbon, top-edge reveal in full screen, and a 150–200 ms page-turn animation (foliate uses 300 ms).
- MOBI/AZW3 path is wired but untested. It needs real DRM-free sample files.
- Real-world corpus (Standard Ebooks, Gutenberg, W3C EPUB 3 tests), UI tests, timing tests in CI, SMB and iCloud-offloaded opens, VoiceOver pass, notarised release and Homebrew cask.

## Licence

[Mozilla Public License 2.0](LICENSE). foliate-js is MIT-licensed; see `PlatenReader/Web/foliate/LICENSE`.
