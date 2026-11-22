#!/bin/sh
# Fetches ONNX Runtime for the iOS app (read aloud's natural voice runs Kokoro
# on it: docs/read-aloud.md) into Vendor/onnxruntime/, which git ignores.
#
# Microsoft's usual homes for the iOS build (its GitHub repository, its Swift
# package and download.onnxruntime.ai) were unreachable on 22 Nov 2026, so
# the build comes from its NuGet package on nuget.org, signed by Microsoft
# and countersigned by nuget.org, at a pinned version and SHA-256. Its
# xcframework has no module map, so one is added to each slice: Swift then
# reads it with `import onnxruntime` (the C API).
#
# Usage: scripts/fetch-onnxruntime.sh   (does nothing if already fetched)
set -eu
VERSION=1.32.0
SHA256=a9150bc2992cbbb6722070da9910e1ffa989a8bfc67bdd5bb8e745ca755641db
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/Vendor/onnxruntime"
STAMP="$OUT/.version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ] && [ -d "$OUT/onnxruntime.xcframework" ]; then
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
URL="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$VERSION/microsoft.ml.onnxruntime.$VERSION.nupkg"
echo "Fetching ONNX Runtime $VERSION from nuget.org…"
curl -sSfL -o "$WORK/ort.nupkg" "$URL"
ACTUAL=$(shasum -a 256 "$WORK/ort.nupkg" | cut -d' ' -f1)
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "ONNX Runtime package checksum mismatch: $ACTUAL (expected $SHA256)" >&2
  exit 1
fi
unzip -q "$WORK/ort.nupkg" "runtimes/ios/native/onnxruntime.xcframework.zip" LICENSE ThirdPartyNotices.txt -d "$WORK" 2>/dev/null \
  || unzip -q "$WORK/ort.nupkg" "runtimes/ios/native/onnxruntime.xcframework.zip" LICENSE -d "$WORK"
rm -rf "$OUT"
mkdir -p "$OUT"
unzip -q "$WORK/runtimes/ios/native/onnxruntime.xcframework.zip" -d "$OUT"
cp "$WORK/LICENSE" "$OUT/LICENSE"
[ -f "$WORK/ThirdPartyNotices.txt" ] && cp "$WORK/ThirdPartyNotices.txt" "$OUT/"

# A module map in each slice, so Swift can import the C API.
for framework in "$OUT"/onnxruntime.xcframework/*/onnxruntime.framework; do
  mkdir -p "$framework/Modules"
  cat > "$framework/Modules/module.modulemap" <<'MAP'
framework module onnxruntime {
    header "onnxruntime_c_api.h"
    export *
    link "c++"
}
MAP
done
echo "$VERSION" > "$STAMP"
echo "ONNX Runtime $VERSION in Vendor/onnxruntime/"
