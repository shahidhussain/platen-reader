# Vendored foliate-js

- Upstream: https://github.com/johnfactotum/foliate-js (MIT, see LICENSE in this folder)
- Pinned commit: 78914aef4466eb960965702401634c2cb348e9b1 (2026-05-01)

Only the files Platen uses are copied. PDF, CBZ, FB2, OPDS, TTS and the zip.js
vendor bundle are left out: Swift reads the zip and serves entries over
`platen://`, so foliate never needs its own zip reader.

## Local patches

None yet. If you patch a file, list it here with the reason, so updates can
re-apply it.

## How to update

1. `git clone https://github.com/johnfactotum/foliate-js && cd foliate-js && git checkout <commit>`
2. Copy the same file list over this folder (see `scripts/update-foliate.sh`).
3. Update the commit above, re-apply local patches, and run the robustness corpus.
