#!/bin/sh
# The robustness corpus on iOS: opens every book in the Debug build of the
# iOS app in the Simulator and checks what happened, as check-corpus.sh does
# for the Mac (the checks themselves are shared: scripts/corpus-cases.sh).
#
# Usage: scripts/check-corpus-ios.sh [--no-build]
#   (after scripts/make-fixtures.py; PLATEN_SIM picks the Simulator, by
#   default the one scripts/run-ios-debug.sh uses)
# Exit status is non-zero if any book fails its check. Takes a few minutes:
# each book is a fresh launch of the app.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G="$ROOT/Fixtures/generated"
FAILED=0

if [ "${1:-}" != "--no-build" ]; then
  xcodebuild -project "$ROOT/PlatenReader.xcodeproj" -scheme "PlatenReader iOS" -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$ROOT/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO build > "$ROOT/build/build-ios.log" 2>&1 \
    || { grep -E "error:" "$ROOT/build/build-ios.log"; exit 1; }
fi

check() {
    file=$1; step=$2; expect=$3; forbid=${4:-}
    [ "$step" = "-" ] && step=""
    out=$(PLATEN_BUILD=0 "$ROOT/scripts/run-ios-debug.sh" "$G/$file" "$step" 2>/dev/null)
    if echo "$out" | grep -aqF -- "$expect" && { [ -z "$forbid" ] || ! echo "$out" | grep -aqF -- "$forbid"; }; then
        echo "PASS  $file"
    else
        # Braces round the names: the curly quote after one was read as
        # part of the name by bash on CI, which stopped the whole run.
        echo "FAIL  ${file} (expected “${expect}”${forbid:+, without “${forbid}”})"
        echo "$out" | sed 's/^/      /' | tail -5
        FAILED=1
    fi
}

# An iPhone's window is already narrow enough for one page.
NARROW=""

. "$ROOT/scripts/corpus-cases.sh"

exit $FAILED
