#!/usr/bin/env bash
# Packages build/OpenSVN.app into a disk image for first-time installation.
#
#   scripts/package-macos-dmg.sh                       # build/OpenSVN-<ver>-macos-arm64.dmg
#   APP=path/to/OpenSVN.app scripts/package-macos-dmg.sh
#   OUT=/tmp/test.dmg scripts/package-macos-dmg.sh
#
# Why a DMG and not the `.zip` this project already ships: the zip exists for the
# updater, which unpacks it into a staging directory and never shows it to a
# person. A first-time install is a different job, and a mounted volume with an
# `Applications` shortcut is the one installation gesture every macOS user
# already knows. Handing a `.app` inside a zip means the download lands in
# Downloads and the user has to decide where to put it; the DMG removes that
# decision.
#
# What this does **not** do is remove Gatekeeper's first-launch prompt. That
# prompt is the notarisation check, and it can only pass with an Apple-issued
# Developer ID certificate. A DMG changes the installation gesture, not the
# trust decision — `Installation Notes.txt` inside the image says so plainly
# instead of letting the user discover it as a failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-$ROOT/build/OpenSVN.app}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

if [[ ! -d "$APP" ]]; then
  echo "error: no bundle at $APP" >&2
  echo "       run scripts/build-macos-app.sh first" >&2
  exit 1
fi

if [[ ! -f "$APP/Contents/Info.plist" ]]; then
  echo "error: $APP is not an application bundle" >&2
  exit 1
fi

# The architecture goes in the name because the bundle is not universal: an
# arm64 build on an Intel Mac opens to an immediate "not supported" dialog, and
# a file name is the only place to say so before that dialog appears.
ARCH="$(lipo -archs "$APP/Contents/MacOS/OpenSVN" 2>/dev/null || echo unknown)"
case "$ARCH" in
  "arm64") ARCH_LABEL="arm64" ;;
  "x86_64") ARCH_LABEL="x86_64" ;;
  *" "*) ARCH_LABEL="universal" ;;
  *) ARCH_LABEL="$ARCH" ;;
esac

OUT="${OUT:-$ROOT/build/OpenSVN-${VERSION}-macos-${ARCH_LABEL}.dmg}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/opensvn-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# `ditto` rather than `cp -R`: it preserves the extended attributes that carry
# the code signature. A copy that drops them produces a bundle that fails
# `codesign --verify` for reasons unrelated to the build.
ditto "$APP" "$STAGE/OpenSVN.app"

# The drop target. A symlink, so the image stays a few hundred bytes larger than
# the app instead of embedding a second copy of /Applications.
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Installation Notes.txt" <<NOTES
OpenSVN ${VERSION} (${ARCH_LABEL})
===============================

Install
  1. Drag OpenSVN.app onto the Applications folder in this window.
  2. Eject this disk image, then open OpenSVN from Applications.

First launch
  OpenSVN is not notarised by Apple, so macOS asks for one approval the first
  time it runs:

    macOS 15 and later
      Double-click the app, dismiss the warning, then open
      System Settings > Privacy & Security, scroll to Security, and choose
      "Open Anyway" for OpenSVN. Right-click > Open no longer works.

    macOS 14
      Right-click the app and choose Open, then confirm.

  This happens once per installation, and never again for updates: OpenSVN
  updates itself in place, and those downloads do not pass through Gatekeeper.

Why the warning exists
  Removing it requires an Apple Developer ID certificate, which costs money
  every year. This project distributes itself through a public repository, so
  releases are signed with the project's own key instead. That key proves where
  the update came from — it just cannot make Apple vouch for it.

Verifying the download
  shasum -a 256 -c SHA256SUMS --ignore-missing
NOTES

# UDZO is compressed and read-only; `-ov` overwrites a stale image from a
# previous run, which otherwise makes hdiutil fail with "file exists".
echo "== creating $OUT"
hdiutil create \
  -volname "OpenSVN ${VERSION}" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  -quiet \
  "$OUT"

echo "== wrote $OUT ($(du -h "$OUT" | cut -f1))"
echo "   mount to inspect: hdiutil attach \"$OUT\""
