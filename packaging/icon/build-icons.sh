#!/bin/bash
#
# build-icons.sh -- redraw every icon from packaging/icon/make-icons.swift.
#
# Writes:
#   mac/menubar/AppIcon.icns      the application icon
#   windows/icons/app.ico         the same tile for Windows
#   windows/icons/<state>.ico     notification area, one per state
#   packaging/icon/build/         PNG sheets to look at, not shipped
#
# Run it after editing the drawing. The generated files are committed so a
# normal build needs no Swift toolchain.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="$HERE/build/make-icons"

mkdir -p "$HERE/build"
echo "compiling the generator ..."
swiftc -O -framework AppKit -o "$BIN" "$HERE/make-icons.swift"

echo "drawing ..."
"$BIN" "$ROOT"

echo "packing the .icns ..."
iconutil -c icns "$HERE/build/AppIcon.iconset" -o "$ROOT/mac/menubar/AppIcon.icns"

echo
echo "wrote:"
echo "  $ROOT/mac/menubar/AppIcon.icns"
ls "$ROOT/windows/icons" | sed "s|^|  windows/icons/|"
