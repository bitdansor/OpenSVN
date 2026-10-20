#!/usr/bin/env bash
# Builds build/OpenSVN.app from the SwiftPM executable target.
#
#   scripts/build-macos-app.sh              # debug, no bundled runtime
#   CONFIG=release scripts/build-macos-app.sh
#   BUNDLE_SVN=1 scripts/build-macos-app.sh # embed a bundled svn runtime
#   BUNDLE_SVN=0 CONFIG=release ...         # release build that still needs a host svn
#
# The bundled runtime defaults ON for release and OFF for debug. A release that
# depends on the build host having svn violates the rule ADR-0003 settled, so the
# opt-out is explicit and the build says so out loud.
#
# The produced bundle is ad-hoc signed. Developer ID signing and notarisation are
# stage 6 work (see docs/development/decisions/ADR-0003-svn-runtime.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/apps/macos"
CONFIG="${CONFIG:-debug}"
APP="$ROOT/build/OpenSVN.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

case "$APP" in
  "$ROOT"/build/OpenSVN.app) ;;
  *) echo "refusing to remove unexpected path: $APP" >&2; exit 1 ;;
esac

cd "$PACKAGE"

# SwiftPM compiles its manifest under sandbox-exec, which some hardened shells
# refuse with "sandbox_apply: Operation not permitted". Such environments can set
# SWIFT_FLAGS=--disable-sandbox; CI leaves it empty.
SWIFT_FLAGS="${SWIFT_FLAGS:-}"

swift build -c "$CONFIG" $SWIFT_FLAGS --product OpenSVN
BIN_DIR="$(swift build -c "$CONFIG" $SWIFT_FLAGS --show-bin-path)"
BIN="$BIN_DIR/OpenSVN"
[[ -x "$BIN" ]] || { echo "error: executable not found at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/OpenSVN"
cp "$PACKAGE/Resources/Info.plist" "$APP/Contents/Info.plist"

# Keep the bundle version in sync with VERSION (CFBundleShortVersionString only
# accepts three dot-separated integers; strip any -dev/-beta suffix).
SHORT_VERSION="${VERSION%%-*}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist" >/dev/null

if [[ "$CONFIG" == "release" ]]; then
  BUNDLE_SVN="${BUNDLE_SVN:-1}"
else
  BUNDLE_SVN="${BUNDLE_SVN:-0}"
fi

if [[ "$BUNDLE_SVN" == "1" ]]; then
  echo "== bundling svn runtime =="
  "$ROOT/scripts/bundle-svn-runtime.sh" "$APP"
else
  echo "== no bundled svn runtime: this build needs svn on PATH =="
  if [[ "$CONFIG" == "release" ]]; then
    echo "   (a release build without the runtime is not shippable — see ADR-0003)"
  fi
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signature: ad-hoc by default so the bundle runs locally on Apple Silicon.
# A real identity switches to the hardened runtime and an inside-out signature;
# `release.yml` never builds without one.
if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
  echo "== signing with '$SIGN_IDENTITY'"
  "$ROOT/scripts/sign-macos-app.sh" "$APP"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
    echo "warning: ad-hoc codesign failed; the app may not launch on Apple Silicon" >&2
  }
  if [[ "$CONFIG" == "release" ]]; then
    echo "   warning: release build is ad-hoc signed — set SIGN_IDENTITY for a shippable artifact"
  fi
fi

echo "== built $APP (OpenSVN $SHORT_VERSION, $CONFIG)"
echo "   open \"$APP\""
