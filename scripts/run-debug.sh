#!/bin/sh
# Opens a book in the Debug build with snapshot hooks enabled and prints the
# app's log. Usage: scripts/run-debug.sh <book> ["js step;js step"]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/DerivedData/Build/Products/Debug/Platen Reader.app/Contents/MacOS/Platen Reader"
mkdir -p "$ROOT/build/snaps"
pkill -f "Platen Reader.app/Contents/MacOS" 2>/dev/null; sleep 0.5
/usr/bin/log stream --level info --style compact --predicate 'subsystem == "Platen Reader"' > "$ROOT/build/app.log" 2>&1 &
LOGPID=$!
sleep 0.5
PLATEN_SNAPSHOT_DIR="$ROOT/build/snaps" PLATEN_STEPS="${2:-}" "$APP" "$1" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
APPPID=$!
STEPS=$(echo "${2:-}" | awk -F';' '{print NF}')
sleep $((5 + STEPS))
kill $APPPID $LOGPID 2>/dev/null
grep -av '^Filtering' "$ROOT/build/app.log" | sed 's/^[0-9-]* [0-9:.]* //' 
