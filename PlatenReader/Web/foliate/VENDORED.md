# Vendored foliate-js

- Upstream: https://github.com/johnfactotum/foliate-js (MIT, see LICENSE in this folder)
- Pinned commit: 78914aef4466eb960965702401634c2cb348e9b1 (2026-05-01)

Only the files Platen uses are copied. PDF, CBZ, FB2, OPDS and the zip.js
vendor bundle are left out (`tts.js` was added on 22 Nov 2026, from the same
pinned commit, for read aloud: `view.initTTS` imports it): Swift reads the zip and serves entries over
`platen://`, so foliate never needs its own zip reader.

## Local patches

If you patch a file, list it here with the reason, so updates can re-apply it.

- `paginator.js`, `#scrollTo`: page-turn animation shortened from 300 ms to
  180 ms, per the spec's 150–200 ms horizontal slide. Marked `// Platen:`.
- `paginator.js`, `#createView` and `#display`: the page being left stays on
  screen until the next section is laid out and scrolled into place, then is
  removed in the same frame, so moving between chapters never flashes a
  blank page. Marked `// Platen:`.
- `paginator.js`, the container's scroll handler: in paginated mode, a scroll
  the paginator did not make (VoiceOver bringing what it reads into view)
  settles on the nearest whole page and is reported as a relocation. Not
  while `holdAlignment` is set (Platen sets it during trackpad swipes).
  Marked `// Platen:`.
- `paginator.js`, `#turnPage`: no 100 ms pause after an unanimated turn
  within a section (upstream waits after every unanimated turn), so fast
  key presses turn pages as fast as they come. Marked `// Platen:`.

- `paginator.js`, `#onTouchEnd`: settles on a page only after a drag, not
  after a tap. Settling from the position before the tap undid the page
  turn the tap asked for (iOS page curl, which turns the page instantly
  underneath). Marked `// Platen:`.

- `paginator.js`, `#onTouchMove`: does nothing when the renderer has the
  `native-swipe` attribute. The iOS app moves the page with the finger
  itself (as a picture, drawn by Core Animation at the screen's full rate),
  because dragging in JavaScript was limited to 60 frames a second and
  stuttered. Marked `// Platen:`.

- `paginator.js`, `#beforeRender`, scrolled flow: the text gets the width
  and side margins of one page (upstream used the whole view, with the
  column gap on each side and the full `max-inline-size`), so switching
  between pages and scrolling does not move or rewrap it. Marked
  `// Platen:`.

- `mobi.js`, pictures in AZW3 books (23 Nov 2026): KF8's `replaceResources`
  drops `srcset` and `sizes`. Converters keep the EPUB's file paths there
  ("../images/logo-2x.png 2x"), which a KF8 book has no files for; WebKit
  took the srcset path over `src` and the picture failed (every picture in
  Standard Ebooks' AZW3s). Also `loadResourceBlob`'s `{ newType }`, an
  upstream typo, is `{ type: newType }`. Checked by the corpus fixture
  `azw3-picture.azw3`, which fails without the srcset change. Marked
  `// Platen:`.

- `tts.js`, `getSegmenter` (24 Nov 2026): line breaks in the text are
  turned into spaces before `Intl.Segmenter` splits sentences, since it ends
  a sentence at every line feed (UAX #29). Books whose paragraphs are
  hard-wrapped in the source (pandoc's EPUBs, at 72 columns) were read
  aloud in fragments, pausing mid-sentence at each line's end. One
  character for one, so offsets are unchanged. Checked by the corpus
  fixture `hard-wrapped.epub`. Marked `// Platen:`. Also there:
  `joinAbbreviations`, which joins a "sentence" ending in a title or common
  abbreviation ("Mr.", "Prof.", "St.", "e.g.") or a lone initial ("J.") to
  the next, since the segmenter breaks after each and read aloud paused
  there.

## How to update

1. `git clone https://github.com/johnfactotum/foliate-js && cd foliate-js && git checkout <commit>`
2. Copy the same file list over this folder (see `scripts/update-foliate.sh`).
3. Update the commit above, re-apply local patches, and run the robustness corpus.
- `fixed-layout.js`, `#createFrame` and `getContents()`: each frame records
  its section index, and `getContents()` returns it (upstream has a TODO).
  Platen needs it to place bookmark ribbons on fixed-layout pages. Marked
  `// Platen`.
