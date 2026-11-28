# Home on the Mac

Status: built (28 Nov 2026, version 1.0.7). Asked for after the first DMG
test, when the Mac's welcome window turned out to have no "Choose Folder…";
then widened the same day to "pretty much up to par with the iOS version".
The spec's decision is "Home on the Mac".

## What it is

The iOS home screen, as a Mac window. It is still not a library: nothing
is imported, copied or catalogued, and the folders on disk are the only
truth ("Files are the library", the spec's first principle). The lists it
keeps are the iOS ones (docs/per-book-data.md, "Recents (iOS and Mac)").

## How it looks

One window, **Home** (`PlatenReader/Sources/HomeWindow.swift`), with a
sidebar, as in Books, Music and Finder:

- **Sidebar:** Home, Favourites and Recent Books (the iOS tabs, in their
  order), then **Folders**: each folder the reader chose, with an icon for
  where it is kept (this Mac, iCloud Drive, a share, a drive). A folder that
  cannot be reached is greyed, with the reason as its tooltip. Folders can be
  dragged into an order; right-click to show one in Finder or remove it; +
  at the foot adds one.
- **Home:** the folders as rows (each with its fan of covers and its path,
  `~/…` for the home folder), then the first favourites (up to six on the
  Mac, at a steady size) with See All. Clicking a folder opens it inside
  Home, with Back.
- **A folder:** its covers, sub-folders first. The search field (title,
  author or file name) is in the toolbar, as in Finder; View Options (order,
  kinds shown, words under each cover) is the filter button. The covers are
  sized rather than counted, so a wider window fits more: a pinch on the
  trackpad makes them bigger or smaller.
- **Favourites and Recent Books:** covers, as on iOS; a book that cannot be
  reached is greyed and says why.
- **A cover's right-click menu:** Add to (or Remove from) Favourites, Get
  Info, Show in Finder; in the lists, Remove.
- **Opening a book:** a click opens it in its own window, as every book has
  always opened (`NSDocument`); Home stays. It joins Recent Books as it opens
  (`BookDocument`), whichever way it was opened.

## When it shows

- At launch, when no book is reopened. Before anything has been opened or
  chosen it is the welcome alone (Open Book…, Choose Folder…, the formats),
  as on iOS; it replaces the old welcome window.
- When the last book window closes.
- **File › Open Folder…** (⇧⌘O) and **Window › Home** (⇧⌘H).

## How it is built

The iOS home screen's views moved into `PlatenReader/Shared` and are used by
both apps; each app supplies only its frame and its `HomeActions`:

| Shared | `HomeViews.swift` (`HomeNavigation`, `HomeActions`, the reach checks, `BookShelfView` for Favourites and Recent Books, `RecentFoldersView` for Home), `FolderView.swift` (the folder grid, tiles, View Options, `CoverColumns`), `HomeSections.swift`, `Favourites.swift`, `FolderCoverFan.swift`, `BookInfoView.swift`, `OfflineSettingsSection.swift`, and `HomePlatform.swift`, the few platform differences in one place |
|---|---|
| iOS only | `HomeTabs.swift` (the sliding tab row and its tab bar), `HomeViewController`, `Favourites+UIKit.swift` (the taps when a favourite is marked), `BookWindows` (iPad windows) |
| Mac only | `HomeWindow.swift` (the window, the sidebar, the Open panels, Show in Finder), the menu items in `MainMenu`, the launch and last-window-closed decisions in `AppDelegate` and `ReaderWindowController`, Keep Favourites on This Mac in Settings › Advanced |

What differs on the Mac, and why:

- **No edit mode.** Folders are dragged into order and removed from their
  menu at any time, as Mac lists work; the order of Home's two sections is
  the iOS one (Folders, then Favourites) unless changed on iOS.
- **No haptics, no "Open in New Window".** Every book already opens in its
  own window.
- **Bookmarks are security-scoped** (`RecentList.bookmark(for:)`), so the
  lists keep working when the Mac App Store build is sandboxed.
- **Cover sizes** come from the window's width (`CoverColumns.macCoverWidth`).

## Checking it

- `PLATEN_FOLDER_PATH=<folder>` opens Home on that folder at launch;
  `PLATEN_HOME_BOOKS` and `PLATEN_HOME_FAVOURITES` (paths separated by `|`)
  fill the lists, and `PLATEN_HOME_TAB=home|favourites|books` picks the part
  (Debug builds, with `PLATEN_TEST_HOME`). With `PLATEN_SNAPSHOT_DIR`, Home
  is saved as `home-window-…png`, and again as `home-settled-…png` once the
  covers have loaded (snapshots of Home are taken from the window server, as
  its sidebar does not draw offscreen).
- `PlatenReaderTests/MacHomeTests.swift` covers what differs on the Mac.

## Not yet done

- A volume on a share mounted in `/Volumes` shows as a drive until it has
  been opened once (the path alone cannot tell; `RecentList.refinePlace`
  learns it).
- Keyboard selection is in a folder's grid only (arrows, Return, Space for
  Quick Look); Recent Books and Favourites take clicks and drags.

Done since (28 Nov 2026): arrow keys, Return and Space (Quick Look) in a
folder's grid; dragging covers out to Finder or Mail; ⌘+, ⌘− and ⌘0 size
the covers while Home is in front (View › Bigger Covers, Smaller Covers,
Default Cover Size).
