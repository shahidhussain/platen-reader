#!/bin/zsh
# Makes the App Store screenshots from scratch: builds the iOS app (Debug,
# into this folder's own build/DerivedData, never Xcode's), captures every
# scene on the iPhone and iPad simulators (capture.py), then adds captions,
# frames and backgrounds (compose.py). See README.md.
#
#   ./build.sh                  everything
#   ./build.sh --compose-only   captions and frames again, from the last captures
#
# PLATEN_SAMPLE_LIBRARY: where the sample books are (default: the main
# checkout's marketing/sample-library, which is not committed).
set -euo pipefail
here=${0:A:h}
cd "$here"
library=${PLATEN_SAMPLE_LIBRARY:-$here/../sample-library}
if [[ ! -d $library ]]; then
  # In a git worktree the library stays in the main checkout.
  main=$(git -C "$here" worktree list --porcelain | sed -n '1s/^worktree //p')
  library=$main/marketing/sample-library
fi

if [[ ${1:-} != --compose-only ]]; then
  echo "Building the iOS app…"
  mkdir -p build
  # Signed ad hoc, so the Simulator shows the launch screen (see docs/m3-ios-plan.md).
  xcodebuild -project ../../PlatenReader.xcodeproj -scheme "PlatenReader iOS" -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build > build/build.log 2>&1 \
    || { grep -E "error:" build/build.log; exit 1; }
  ./capture.py --library "$library"
fi
./compose.py
