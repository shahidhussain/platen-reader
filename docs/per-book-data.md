# Per-book data format

Platen stores one JSON file per book:

```
~/Library/Application Support/Platen Reader/books/<key>.json
```

`key` is the first 32 hex digits of `SHA-256("<OPF unique identifier>|<fingerprint>")`. The fingerprint is `<file size>-<first 24 hex digits of SHA-256(first 64 KB + last 64 KB)>`. Because the key never depends on the path, it survives renames and moves.

```json
{
  "bookmarks" : [
    {
      "cfi" : "epubcfi(/6/8!/4/2/10/1:0)",
      "chapter" : "Chapter 1",
      "created" : "2026-11-09T13:55:10Z",
      "fraction" : 0.031,
      "page" : "4",
      "snippet" : "It was a bright cold day"
    }
  ],
  "fingerprint" : "325805-72f3a294043ff3286c947d3a",
  "key" : "6999b1b98200e4b6899381de21a9a27e",
  "lastCFI" : "epubcfi(/6/4!/4,/22/1:364,/32/1:371)",
  "lastKnownPath" : "/Users/me/Books/novel.epub",
  "lastOpened" : "2026-11-09T13:55:10Z",
  "schemaVersion" : 1,
  "uniqueIdentifier" : "urn:uuid:…"
}
```

- In a bookmark, `chapter`, `page` and `fraction` are optional; `fraction` only orders the bookmarks list.
- `lastKnownPath` is informational only and is never used to find the book.
- **PDFs** use the same file. The key uses `pdf:<document ID>` (the first part of the PDF trailer's `/ID`) in place of the OPF identifier. `lastPage` is the page shown when last read (counting from 0), `lastZoom` the zoom if the reader zoomed (absent when the page was fitted to the window), and each bookmark's `cfi` is `page:<index>`. `lastCFI` is not used.
- Older files may have `readingMode` (`paginated` or `scrolled`). It is ignored: scroll or pages is one setting for every book.
- Writes are atomic: Platen writes a temporary file and renames it over the old one. Saves after page turns are debounced by 0.75 s; closing the window saves immediately.
- Settings > Advanced > Clear deletes the whole `books` folder.

## Recents (iOS and Mac)

At the reader's request (15 Nov 2026), the iOS home screen keeps short lists for its tabs: Recent Books, the Home tab's folders (only folders the reader chose, not ones browsed into), and, at the reader's request (21 Nov 2026), Favourites (books marked from a cover's long-press menu, in a folder or in Recent Books):

```
~/Library/Application Support/Platen Reader/recents/books.json
~/Library/Application Support/Platen Reader/recents/folders.json
~/Library/Application Support/Platen Reader/recents/favorites.json
~/Library/Application Support/Platen Reader/recents/covers/<id>.jpg
```

Each entry has an `id`, a `bookmark` (the system's reference to the file or folder, which keeps permission to read it and is how it is found again), its `name`, the `path` it was at (to recognise it when opened again, and to show which folder it is in; never used to open it), `lastOpened`, and for books the `title` and `author` and whether a copy of the cover is kept (`hasCover`, a small JPEG in `covers/`, so the list shows it even when the book cannot be reached). At most 60 recent books and folders are kept, newest first (favourites are not trimmed). A long press on an item removes it, with its cover copy; nothing else about the book is touched.

### On the Mac

At the reader's request (28 Nov 2026), the Mac has the same home screen (its Home window; docs/mac-folder-view-plan.md) and keeps the same lists, in the same files and the same form: Recent Books (a book joins it as it opens, from Finder, Home or File › Open), the folders the reader chose, and Favourites, with the cover copies. Favourites kept elsewhere are copied to the Mac too ("Offline copies" below; Settings › Advanced › Keep Favourites on This Mac). The Mac's own File › Open Recent menu is the system's, as before. On the Mac the bookmarks are made security-scoped, so the lists keep working when the Mac App Store build is sandboxed. Automated runs (`scripts/run-debug.sh`, the corpus checks) keep all of this in a throwaway place (`PLATEN_TEST_HOME`).

## Offline copies of favourites (iOS and Mac)

At the reader's request (25 Nov 2026), a favourite kept somewhere other than this device (iCloud Drive or another cloud, a network share, a drive) is copied to the device, so it can be read offline or away from the share:

```
~/Library/Application Support/Platen Reader/offline/<favourite id>/<file name>
```

The copy is made when the book is marked as a favourite (or the next time its place answers), and made again when the original changes. Books already on the device are not copied. Removing a book from Favourites deletes its copy at once, so the only books copied are the current favourites; marking it again copies it afresh from its place. Settings › Offline › Keep Favourites on This Device (on by default) turns this off and deletes every copy. A favourite opens from its own place whenever that answers, and from the copy only when it does not; reading positions and bookmarks follow the book's contents, so both open at the same place. Opening a copy does not add it to Recent Books. The copies are excluded from iCloud backup, as they can be made again.

## Diagnostics (iOS)

At the reader's request (22 Nov 2026), the iOS app keeps a record of how it has been running, to share from Settings > Share Diagnostics… when reporting a problem:

```
~/Library/Application Support/Platen Reader/Diagnostics/Diagnostics.txt
```

It is plain text, one timestamped line per log entry at info level and above: a line at each launch naming the app's version, the iOS version and the device's model code (never the name its owner gave it), how long books took to open, moments the app was too busy to answer a tap, and errors. It is not per-book data: book titles, file names and searches are written as `<name>`, and a book is described only by its kind and size. It is kept to about 512 KB, the oldest lines dropped first. Nothing sends it anywhere; it leaves the device only through the share sheet. Sharing makes a copy in the app's temporary folder, named for the date and time it was made (`Platen Reader Diagnostics 2026-11-22 at 10.41.14.txt`).

## Read aloud

Read aloud keeps no per-book data. Its settings are global, like every other setting: an Apple voice chosen in Settings (`readAloudAppleVoice`; none means the best installed for each book's language), the speed (`readAloudSpeed`), and a flag per language once the note about better Apple voices has been shown (`readAloudVoiceNoteShown.<language>`). (`readAloudChoice` and `readAloudKokoroVoice` belong to the parked natural voice and are not set while it is parked.) See `docs/read-aloud.md`.

Portability between apps is not a goal. The format is documented so people can inspect, back up or delete their own data.
