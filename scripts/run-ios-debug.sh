#!/bin/zsh
# Opens a book in the iOS app in the Simulator, runs optional scripted steps,
# takes screenshots and prints the reader's log. The iOS counterpart of
# run-debug.sh, for checking the iOS reader without touching the Simulator.
#
# Usage:
#   scripts/run-ios-debug.sh <book> ["<step>;<step>;…"]
#
# Steps run 1.5 s apart after the first page renders (see
# "PlatenReader iOS/Sources/DebugHooks.swift"): "@tap:left|centre|right",
# "@close", or JavaScript such as "platen.next()" (string results are logged
# as "step result:"). A screenshot is taken after the first render and after
# each step: build/snaps-ios/<book>-N.png.
#
# Environment:
#   PLATEN_SIM     Simulator name or UDID (default: iPhone 18 Pro Max)
#   PLATEN_BUILD=0 skip building (use the last Debug build)
#   PLATEN_OPEN_DELAY  seconds to wait after launch before opening the book
#
# The book is copied into the app's own Documents folder first: coordinated
# reads of files on the Mac's disk stall in the Simulator, while files in the
# app's container (or any file provider) open as they would on a device.
set -euo pipefail
cd "$(dirname "$0")/.."

book=${1:?usage: run-ios-debug.sh <book> [steps]}
steps=${2:-}
sim=${PLATEN_SIM:-iPhone 18 Pro Max}
bundle=org.platenreader.PlatenReader
app="build/DerivedData/Build/Products/Debug-iphonesimulator/Platen Reader.app"
snaps=build/snaps-ios
name=$(basename "$book"); name=${name%%.*}

if [[ ${PLATEN_BUILD:-1} != 0 ]]; then
  xcodebuild -project PlatenReader.xcodeproj -scheme "PlatenReader iOS" -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO build > build/build-ios.log 2>&1 \
    || { grep -E "error:" build/build-ios.log; exit 1; }
fi

# Boot the Simulator if needed (bootstatus -b boots and waits).
xcrun simctl bootstatus "$sim" -b > /dev/null
xcrun simctl terminate "$sim" $bundle 2> /dev/null || true
xcrun simctl install "$sim" "$app"

documents="$(xcrun simctl get_app_container "$sim" $bundle data)/Documents"
mkdir -p "$documents" "$snaps"
cp "$book" "$documents/"
rm -f "$snaps/$name"-*.png(N)

started=$(date "+%Y-%m-%d %H:%M:%S")
SIMCTL_CHILD_PLATEN_OPEN_DELAY=${PLATEN_OPEN_DELAY:-0} SIMCTL_CHILD_PLATEN_OPEN_PATH="$documents/$(basename "$book")" SIMCTL_CHILD_PLATEN_STEPS="$steps" \
  xcrun simctl launch "$sim" $bundle > /dev/null

# First render takes about a second; then one screenshot per step.
count=$(( ${#steps} == 0 ? 0 : $(tr -cd ';' <<< "$steps" | wc -c) + 1 ))
sleep $(( 2.5 + ${PLATEN_OPEN_DELAY:-0} ))
xcrun simctl io "$sim" screenshot "$snaps/$name-0.png" > /dev/null 2>&1
for i in $(seq 1 $count); do
  sleep 1.5
  xcrun simctl io "$sim" screenshot "$snaps/$name-$i.png" > /dev/null 2>&1
done
sleep 0.5

xcrun simctl spawn "$sim" log show --start "$started" --info --debug --style compact \
  --predicate 'subsystem == "Platen Reader"' 2> /dev/null \
  | sed -n 's/.*\[Platen Reader:reader\] //p'
echo "screenshots: $snaps/$name-*.png"
