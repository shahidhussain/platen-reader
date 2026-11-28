# A folder view for the Mac: plan

Status: agreed (28 Nov 2026), not started. Asked for after the first DMG
test, when the Mac's welcome window turned out to have no "Choose Folder…"
(the iOS one does). Target: 1.1, after the Mac 1.0 download ships.

## What it is

The iOS home screen's folder view, made a Mac window: choose a folder and
see its books as a grid of covers, folders inside it first, search and
filter by kind, and double-click to read. It is still not a library:
nothing is imported, copied or catalogued, and the folder on disk is the
only truth ("Files are the library", the spec's first principle). Finder
stays a perfectly good way in; this is a nicer one for people who keep
their books in one or two folders.

## How it looks (the Mac's own idiom, not the iPhone's tabs)

One window, **Home**, with a sidebar (SwiftUI `NavigationSplitView`), as in
Finder, Music and Notes:

- **Sidebar:** Home (the welcome: Open Book…, Open Folder…, the formats),
  Recent Books, and then each chosen folder by name, with its storage
  (iCloud, this Mac, a share, a drive) as a small icon. Right-click a folder
  to remove it or show it in Finder; + at the bottom adds one; folders can
  be dragged in from Finder.
- **Detail:** the folder's covers, sized by a slider in the toolbar (the
  Finder's icon-size control), sub-folders first; a toolbar search field
  (⌘F) for file name, title and author; the kind filter and the sort in a
  toolbar menu. A path bar under the grid, or the window's title menu,
  steps back up to the folder chosen.
- **Opening a book:** double-click or Return opens it in its own book
  window, as every book opens now (`NSDocument`); the Home window stays.
  Space shows Quick Look, as in Finder. Arrow keys move through the covers.
  Drag a cover out to Finder or Mail as the file itself.
- **Recent Books** on the Mac is the system's own list (`NSDocumentController`
  recent documents, the same as File › Open Recent), shown as covers. No new
  list is stored for it.

## When it shows

- At launch, when no book is reopened: the Home window instead of today's
  welcome window. Before any folder is chosen it shows Home, which is the
  welcome as it is now plus "Open Folder…", so a first launch looks the same.
- From the menus: **File › Open Folder…** (⇧⌘O) and **Window › Home**
  (⇧⌘H, as Finder uses for the home folder), at any time.
- Closing it is fine; it is never the app's only way in.

## What is reused, and what is new

Most of the work is already shared and platform-neutral in
`PlatenReader/Shared` (it compiles into the Mac app today, unused):

| Reused as is | `FolderModel`, `FolderScanner`, `FolderListingCache`, `CoverImages` (covers as `CGImage`, Quick Look thumbnails), `BookTypeFilter`, `FolderSort`, `FolderSearch`, `RecentList`, `StoragePlace` and the new move guard, `CoverLook` |
|---|---|
| Moved to Shared, split by platform | `FolderView.swift` (661 lines; its one iOS tie is the foreground notification) and the cover cell from `FolderCoverFan.swift`; iOS-only modifiers (the search drawer, pull-to-refresh, the tab row's room below) move into a `+UIKit` file |
| New, Mac only | `HomeWindow.swift` (the window, the sidebar, menus, Quick Look, drag out), File › Open Folder… and Window › Home in `MainMenu`, the launch decision in the app delegate, the welcome window folded into Home |
| Left out on the Mac | Favourites and offline copies (iOS answers to files that may not be on the phone; a Mac's iCloud Drive keeps files itself), Book Info sheet (Finder's Get Info does it) |

## Rules this touches (decisions needed)

1. **Per-book data: agreed 28 Nov 2026.** The Mac keeps the list of
   folders chosen (names, paths, bookmarks, in `recents/folders.json`), as
   iOS does; Recent Books needs nothing stored. Recorded in the spec's
   "Decisions made" and in per-book-data.md ("On the Mac").
2. **The sandbox, later.** The direct download is not sandboxed, so a
   chosen folder can be read again at the next launch without asking. The
   Mac App Store build will be: folder bookmarks are therefore made with
   `.withSecurityScope` on the Mac from the start, and access is opened and
   closed around each read, so nothing changes when the sandbox arrives.
3. **Launch.** "Launching never lands in a file browser" stays true: a book
   left open still reopens directly; the Home window is what shows when
   there is no book, in place of the welcome.

## Phases

1. **Share the folder view** (about a day). Move `FolderView` and the cover
   cell into Shared with the iOS parts split off; the iOS app must look and
   behave exactly as before (`scripts/ios-matrix.py`, the folder hooks in
   `run-ios-debug.sh`).
2. **The Home window** (two to three days). Sidebar, grid, search, filter,
   sort, size slider, opening books, Open Folder…, Window › Home, the launch
   decision; the welcome folded in. A Debug hook, `PLATEN_FOLDER_PATH` as on
   iOS, opens a folder in Home for `run-debug.sh` snapshots.
3. **Recent folders and Recent Books on the Mac** (a day). Security-scoped
   bookmarks, the move guard, folders on shares and drives that are not
   mounted shown as unavailable (as on iOS), Recent Books from the system's
   list.
4. **Finder manners** (a day). Quick Look on Space, drag out, Show in
   Finder, arrow keys and type-to-select, VoiceOver names for covers and
   folders, Reduce Motion.
5. **Checks and docs.** Tests in `PlatenReaderTests` for anything new in
   Shared (the bookmark options, the launch decision if it is shared logic);
   a UI test that opens a fixture folder and a book from it; spec, README,
   per-book-data.md and the welcome's strings. A version bump per change, as
   always.

About a week in all, most of it in phase 2.

## Open questions for you

- One Home window, or one per folder (Finder's ⌘N)? The plan says one:
  simpler, and it is a reader, not a file manager.
- Should the Mac app remember that Home was open at quit and bring it back,
  alongside reopened books? The plan says yes.
