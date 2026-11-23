#!/bin/zsh
# Checks that reading aloud with the natural voice opens no network connection.
#
# The natural voice is our own code on Accelerate (KokoroModel), with no
# machine-learning runtime: ONNX Runtime, tried first, connected to
# mobile.events.data.microsoft.com unless switched off (22 Nov 2026). This
# opens a book in the Simulator, reads aloud with the natural voice for about
# 15 seconds, quits the app (telemetry is often sent on the way out), and
# watches the app's sockets throughout. Run it after touching the natural
# voice or adding any library.
#
# Usage: scripts/check-no-network.sh   (after building the iOS app for the
#   Simulator and python3 scripts/make-kokoro-pack.py)
set -u
cd "$(dirname "$0")/.."
sim=${PLATEN_SIM:-iPhone 18 Pro Max}
pack="$PWD/build/kokoro-pack"
[ -d "$pack" ] || { echo "No voice pack: run python3 scripts/make-kokoro-pack.py"; exit 1; }
seen=$(mktemp)

PLATEN_SIM="$sim" PLATEN_KOKORO_PACK="$pack" PLATEN_BUILD=0 PLATEN_WAIT=8 scripts/run-ios-debug.sh \
  Fixtures/generated/novel.epub "@voice:kokoro;@readaloud;@wait;@wait;@wait;@wait;@wait;@wait;@wait;@wait;@wait;@wait;@readaloud:stop" \
  > /dev/null 2>&1 &
runner=$!
watch() {
  local pid=$(pgrep -f "Platen Reader.app/Platen Reader" | head -1)
  [ -n "$pid" ] && lsof -nP -a -i -p $pid 2>/dev/null | tail -n +2 >> "$seen"
}
for i in $(seq 1 120); do watch; sleep 0.5; done
wait $runner
xcrun simctl terminate "$sim" org.platenreader.PlatenReader 2>/dev/null
for i in $(seq 1 6); do watch; sleep 0.5; done

if [ -s "$seen" ]; then
  echo "FAIL  the app opened network connections while reading aloud:"
  sort -u "$seen" | awk '{print "      " $8, $9, $10}'
  rm -f "$seen"; exit 1
fi
rm -f "$seen"
echo "PASS  no network connections while reading aloud with the natural voice"
