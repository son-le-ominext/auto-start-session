#!/bin/bash
#
# build.sh -- produce the downloadable installers in dist/.
#
#   packaging/build.sh              # both installers
#   packaging/build.sh mac          # only the macOS .pkg
#   packaging/build.sh windows      # only the Windows Setup.cmd
#
# Outputs:
#   dist/ClaudeAutoStart-<version>.pkg        macOS installer (needs macOS to build)
#   dist/ClaudeAutoStart-<version>-Setup.cmd  Windows single-file installer (builds anywhere)
#
# Signing the .pkg (optional, needs an Apple Developer ID Installer certificate):
#   SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" packaging/build.sh mac
# Unsigned packages install fine but Gatekeeper asks the user to right-click > Open.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
WORK="$(mktemp -d -t claude-auto-start-build)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$DIST"

build_mac() {
	if ! command -v pkgbuild >/dev/null; then
		echo "skip mac: pkgbuild not found (build the .pkg on macOS)" >&2
		return 0
	fi
	echo "== macOS .pkg =="
	mkdir -p "$WORK/mac-root/Applications" "$WORK/scripts"

	# The app is the payload: it carries the shell scripts in its Resources, so
	# one bundle in /Applications is the whole install.
	"$ROOT/mac/menubar/build-app.sh" "$WORK/mac-root/Applications" >/dev/null

	# Keep the loose copy in dist/ in step with the package. Without this it is
	# whatever build-app.sh last wrote there, which is a good way to install a
	# stale build by hand and not notice.
	rm -rf "$DIST/Claude Auto Start.app"
	ditto "$WORK/mac-root/Applications/Claude Auto Start.app" "$DIST/Claude Auto Start.app"

	# Copy the install scripts by content rather than with cp: cp carries over
	# extended attributes (com.apple.provenance) that pkgbuild would archive as
	# ._ twin files.
	local f
	for f in "$ROOT"/packaging/mac/scripts/*; do
		cat "$f" > "$WORK/scripts/$(basename "$f")"
		chmod 755 "$WORK/scripts/$(basename "$f")"
	done
	xattr -cr "$WORK/scripts" 2>/dev/null || true

	# pkgbuild may print "write: Permission denied" from a sandboxed cache; harmless.
	pkgbuild --root "$WORK/mac-root" \
		--identifier com.ominext.claude-auto-start \
		--version "$VERSION" \
		--scripts "$WORK/scripts" \
		--install-location / \
		"$WORK/ClaudeAutoStart-component.pkg" >/dev/null

	sed "s/__VERSION__/$VERSION/g" "$ROOT/packaging/mac/Distribution.xml" > "$WORK/Distribution.xml"

	local out="$DIST/ClaudeAutoStart-$VERSION.pkg"
	local args=(--distribution "$WORK/Distribution.xml" --resources "$ROOT/packaging/mac/resources" --package-path "$WORK")
	if [ -n "${SIGN_IDENTITY:-}" ]; then
		productbuild "${args[@]}" --sign "$SIGN_IDENTITY" "$out" >/dev/null
		echo "signed with: $SIGN_IDENTITY"
	else
		productbuild "${args[@]}" "$out" >/dev/null
	fi
	echo "$out"
}

build_windows() {
	echo "== Windows Setup.cmd =="
	local zip="$WORK/payload.zip"
	( cd "$ROOT/windows" && zip -q -X -r "$zip" \
		start-session.ps1 tray.ps1 install.ps1 uninstall.ps1 status.ps1 config.example.ps1 icons )

	local out="$DIST/ClaudeAutoStart-$VERSION-Setup.cmd"
	{
		sed "s/__VERSION__/$VERSION/g" "$ROOT/packaging/windows/setup-header.cmd"
		echo "::PAYLOAD-BEGIN"
		base64 < "$zip" | tr -d '\n' | fold -w 76 | sed 's/^/::/'
		echo
		echo "::PAYLOAD-END"
	} | sed 's/\r$//; s/$/\r/' > "$out"      # cmd.exe wants CRLF
	echo "$out"
}

case "${1:-all}" in
	mac)     build_mac ;;
	windows) build_windows ;;
	all)     build_mac; build_windows ;;
	*) echo "usage: $0 [mac|windows|all]" >&2; exit 2 ;;
esac

echo
ls -lh "$DIST"
