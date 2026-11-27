#!/bin/sh
# Makes the disk image people download: Platen Reader beside a shortcut to
# Applications, so installing is dragging one onto the other.
#
#   scripts/make-dmg.sh <Platen Reader.app> <out.dmg> ["Developer ID Application"]
#
# With a signing identity (the third argument) the image itself is signed
# too, as notarisation needs; without one it is left unsigned, for looking
# at locally. The release workflow (.github/workflows/release.yml) runs this
# on the notarised and stapled app, then notarises and staples the image.
#
# Only Apple's own tools are used (hdiutil, ditto, xattr, codesign), so the
# build machine needs nothing installed. The window is left plain (Finder's
# default view of the two icons): a background picture would need Finder
# scripting on the build machine, which is unreliable on CI runners.
set -eu

if [ $# -lt 2 ]; then
    echo "usage: $0 <app> <out.dmg> [signing identity]" >&2
    exit 2
fi
APP=$1
OUT=$2
IDENTITY=${3:-}
NAME="Platen Reader"   # the volume's name, shown in Finder's sidebar

[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'hdiutil detach -quiet "$WORK/mount" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# What goes on the image: the app (ditto keeps its signature, stapled
# ticket and extended attributes intact) and the Applications shortcut.
mkdir "$WORK/content"
ditto "$APP" "$WORK/content/$NAME.app"
ln -s /Applications "$WORK/content/Applications"

# A writable image first, so the volume can be given the app's icon.
# HFS+ rather than APFS: Finder shows a custom volume icon on HFS+ images,
# and every macOS the app runs on (14 and later) mounts them.
hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/content" \
    -fs HFS+ -format UDRW "$WORK/rw.dmg"
mkdir "$WORK/mount"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$WORK/mount" "$WORK/rw.dmg"

# The volume icon: the app's own icon as .VolumeIcon.icns (hidden by its
# leading dot), and the volume's "has custom icon" Finder flag set. The flag
# is bit 0x0400 of the Finder flags, bytes 8 and 9 of the 32-byte FinderInfo.
ICON="$APP/Contents/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$WORK/mount/.VolumeIcon.icns"
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" "$WORK/mount"
fi

hdiutil detach -quiet "$WORK/mount"

# Compressed and read-only for download (LZFSE: smaller than zlib, and read
# by every macOS since 10.11).
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$OUT"

if [ -n "$IDENTITY" ]; then
    codesign --sign "$IDENTITY" --timestamp "$OUT"
    codesign --verify --verbose=2 "$OUT"
fi
echo "made $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
