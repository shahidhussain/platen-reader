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

## Recents (iOS)

At the reader's request (15 Nov 2026), the iOS home screen keeps short lists for its tabs: Recent Books, the Home tab's folders (only folders the reader chose, not ones browsed into), and, at the reader's request (21 Nov 2026), Favourites (books marked from a cover's long-press menu, in a folder or in Recent Books):

```
~/Library/Application Support/Platen Reader/recents/books.json
~/Library/Application Support/Platen Reader/recents/folders.json
~/Library/Application Support/Platen Reader/recents/favorites.json
~/Library/Application Support/Platen Reader/recents/covers/<id>.jpg
```

Each entry has an `id`, a `bookmark` (the system's reference to the file or folder, which keeps permission to read it and is how it is found again), its `name`, the `path` it was at (to recognise it when opened again, and to show which folder it is in; never used to open it), `lastOpened`, and for books the `title` and `author` and whether a copy of the cover is kept (`hasCover`, a small JPEG in `covers/`, so the list shows it even when the book cannot be reached). At most 60 recent books and folders are kept, newest first (favourites are not trimmed). A long press on an item removes it, with its cover copy; nothing else about the book is touched.

Portability between apps is not a goal. The format is documented so people can inspect, back up or delete their own data.
