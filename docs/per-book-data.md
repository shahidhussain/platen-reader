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
  "readingMode" : "paginated",
  "schemaVersion" : 1,
  "uniqueIdentifier" : "urn:uuid:…"
}
```

- In a bookmark, `chapter`, `page` and `fraction` are optional; `fraction` only orders the bookmarks list.
- `lastKnownPath` is informational only and is never used to find the book.
- **PDFs** use the same file. The key uses `pdf:<document ID>` (the first part of the PDF trailer's `/ID`) in place of the OPF identifier. `lastPage` is the page shown when last read (counting from 0), `lastZoom` the zoom if the reader zoomed (absent when the page was fitted to the window), and each bookmark's `cfi` is `page:<index>`. `lastCFI` is not used.
- `readingMode` is `paginated` or `scrolled`, as it was when the book was closed.
- Writes are atomic: Platen writes a temporary file and renames it over the old one. Saves after page turns are debounced by 0.75 s; closing the window saves immediately.
- Settings > Advanced > Clear deletes the whole `books` folder.

Portability between apps is not a goal. The format is documented so people can inspect, back up or delete their own data.
