#!/bin/bash
#
# build-app.sh -- compile the menu bar app into a .app bundle.
#
#   mac/menubar/build-app.sh [output-dir]
#
# Produces "<output-dir>/Claude Auto Start.app". The shell scripts are copied
# into Contents/Resources so the app can install, retime and remove the
# schedule on its own, with no dependency on where the repo lives.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACDIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$MACDIR/.." && pwd)"
OUT="${1:-$ROOT/dist}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

APP="$OUT/Claude Auto Start.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Build both slices where the SDK allows it, so one .pkg covers Apple silicon
# and Intel. The arm64 slice is required; x86_64 is best effort.
BIN="$APP/Contents/MacOS/ClaudeAutoStart"

echo "compiling arm64 ..."
swiftc -O -target arm64-apple-macos13.0 -framework AppKit -o "$BIN.arm64" "$HERE/main.swift"

if swiftc -O -target x86_64-apple-macos13.0 -framework AppKit \
		-o "$BIN.x86_64" "$HERE/main.swift" 2>/dev/null; then
	echo "compiling x86_64 ... ok, making it universal"
	lipo -create -output "$BIN" "$BIN.arm64" "$BIN.x86_64"
	rm -f "$BIN.arm64" "$BIN.x86_64"
else
	echo "x86_64 slice unavailable, shipping arm64 only"
	mv "$BIN.arm64" "$BIN"
fi
chmod 755 "$BIN"

sed "s/__VERSION__/$VERSION/g" "$HERE/Info.plist.template" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The scripts the app drives. Copied by content so no extended attributes
# ride along into the installer payload.
for f in "$MACDIR"/*.sh "$MACDIR"/*.plist.template; do
	name="$(basename "$f")"
	[ "$name" = "config.local.sh" ] && continue
	cat "$f" > "$APP/Contents/Resources/$name"
	chmod 755 "$APP/Contents/Resources/$name"
done

# Icon, if one has been generated next to the source.
if [ -f "$HERE/AppIcon.icns" ]; then
	cat "$HERE/AppIcon.icns" > "$APP/Contents/Resources/AppIcon.icns"
fi

# An ad-hoc signature keeps macOS from killing the app on first launch.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
	&& echo "ad-hoc signed" || echo "warning: could not ad-hoc sign"

# Best effort tidy up. Some macOS builds stamp com.apple.provenance on every
# file they write and refuse to let it be removed; pkgbuild then archives each
# one as a ._ twin inside the package. Those twins are inert -- Installer folds
# them back into metadata and never writes ._ files to disk -- so a package
# that still contains them is fine.
xattr -cr "$APP" 2>/dev/null || true
codesign -v "$APP" 2>/dev/null || echo "warning: signature is not valid"

echo "$APP"
