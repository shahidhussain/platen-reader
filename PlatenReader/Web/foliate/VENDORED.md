# Vendored foliate-js

- Upstream: https://github.com/johnfactotum/foliate-js (MIT, see LICENSE in this folder)
- Pinned commit: 78914aef4466eb960965702401634c2cb348e9b1 (2026-05-01)

Only the files Platen uses are copied. PDF, CBZ, FB2, OPDS, TTS and the zip.js
vendor bundle are left out: Swift reads the zip and serves entries over
`platen://`, so foliate never needs its own zip reader.

## Local patches

If you patch a file, list it here with the reason, so updates can re-apply it.

- `paginator.js`, `#scrollTo`: page-turn animation shortened from 300 ms to
  180 ms, per the spec's 150–200 ms horizontal slide. Marked `// Platen:`.
- `paginator.js`, `#createView` and `#display`: the page being left stays on
  screen until the next section is laid out and scrolled into place, then is
  removed in the same frame, so moving between chapters never flashes a
  blank page. Marked `// Platen:`.
- `paginator.js`, `#turnPage`: no 100 ms pause after an unanimated turn
  within a section (upstream waits after every unanimated turn), so fast
  key presses turn pages as fast as they come. Marked `// Platen:`.

## How to update

1. `git clone https://github.com/johnfactotum/foliate-js && cd foliate-js && git checkout <commit>`
2. Copy the same file list over this folder (see `scripts/update-foliate.sh`).
3. Update the commit above, re-apply local patches, and run the robustness corpus.
- `fixed-layout.js`, `#createFrame` and `getContents()`: each frame records
  its section index, and `getContents()` returns it (upstream has a TODO).
  Platen needs it to place bookmark ribbons on fixed-layout pages. Marked
  `// Platen`.
