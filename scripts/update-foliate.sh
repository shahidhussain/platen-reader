#!/bin/sh
# Re-vendors foliate-js at a given commit into PlatenReader/Web/foliate.
# Usage: scripts/update-foliate.sh <commit>
set -eu
COMMIT=${1:?usage: update-foliate.sh <commit>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
git clone -q https://github.com/johnfactotum/foliate-js "$TMP/foliate-js"
git -C "$TMP/foliate-js" checkout -q "$COMMIT"
DEST="$ROOT/PlatenReader/Web/foliate"
for f in LICENSE view.js epub.js epubcfi.js progress.js overlayer.js text-walker.js \
         paginator.js fixed-layout.js mobi.js search.js footnotes.js; do
  cp "$TMP/foliate-js/$f" "$DEST/$f"
done
cp "$TMP/foliate-js/vendor/fflate.js" "$DEST/vendor/fflate.js"
echo "Copied foliate-js $COMMIT. Update VENDORED.md and re-apply local patches."
