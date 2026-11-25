#!/bin/sh
# Opens every book in the robustness corpus in the Debug build and checks
# what actually happened: that it rendered (and, for some, what is on the
# page), or that it failed with the expected message.
#
# Usage: scripts/check-corpus.sh        (after building Debug and running
#                                        scripts/make-fixtures.py)
# Exit status is non-zero if any book fails its check.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G="$ROOT/Fixtures/generated"
FAILED=0

# check <file> <step or -> <expected log substring> [<substring that must NOT appear>]
check() {
    file=$1; step=$2; expect=$3; forbid=${4:-}
    [ "$step" = "-" ] && step=""
    out=$("$ROOT/scripts/run-debug.sh" "$G/$file" "$step" 2>/dev/null)
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

# A window narrow enough for one page (an iPhone's already is).
NARROW="@resize:500x800;"

. "$ROOT/scripts/corpus-cases.sh"

exit $FAILED
