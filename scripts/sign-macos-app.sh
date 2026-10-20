#!/usr/bin/env bash
# Signs the app and everything inside it, inside-out, with the hardened runtime.
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#     scripts/sign-macos-app.sh build/OpenSVN.app
#
# Why this is a separate script instead of a flag on the build:
#
#   * The order is not optional. `codesign --deep` is explicitly not for signing
#     (Apple's own guidance); a bundled dylib signed after its parent leaves the
#     parent's signature covering bytes that changed. On Apple Silicon that is a
#     SIGKILL at launch, not an error message.
#   * `--options runtime` must be applied to every nested binary, not just the
#     app, or notarisation rejects the submission for an unsigned-unsafe inner
#     executable.
#
# Signing with an Apple Development identity works locally but cannot be
# notarised. The script says so rather than letting a release job fail later at
# `notarytool submit` with a much less obvious message.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/OpenSVN.app}"
IDENTITY="${SIGN_IDENTITY:-}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/packaging/macos/entitlements.plist}"

[[ -d "$APP/Contents" ]] || { echo "error: no app bundle at $APP" >&2; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "error: no entitlements at $ENTITLEMENTS" >&2; exit 1; }

if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  cat >&2 <<'MSG'
error: SIGN_IDENTITY is not set.

  signing with "-" (ad-hoc) is what an unsigned local build does; it is not
  this script. Set the identity explicitly:

    security find-identity -v -p codesigning          # what is available
    SIGN_IDENTITY="Developer ID Application: ... (TEAMID)" scripts/sign-macos-app.sh
MSG
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "error: no such signing identity in the keychain: $IDENTITY" >&2
  echo "       available:" >&2
  security find-identity -v -p codesigning | sed 's/^/         /' >&2
  exit 1
fi

SHIPPABLE=0
case "$IDENTITY" in
  "Developer ID Application:"*) SHIPPABLE=1 ;;
  *)
    echo "warning: '$IDENTITY' is not a Developer ID Application identity." >&2
    echo "         The signature will be valid locally but notarisation will reject it." >&2
    ;;
esac

# Ad-hoc signatures left over from an earlier build would make the outer
# signature cover stale nested code, so start from the inside every time.
sign_one() {
  local target="$1"; shift
  if codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@" "$target" 2>/dev/null; then
    return 0
  fi
  if [[ "$SHIPPABLE" -eq 0 ]]; then
    # A development certificate plus an offline timestamp server is a normal
    # combination on a laptop. A Developer ID build never gets this fallback:
    # an untimestamped signature cannot be notarised, and hiding that would
    # move the failure to release time.
    echo "  note: retrying $(basename "$target") without a timestamp (local only)" >&2
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@" "$target"
    return 0
  fi
  return 1
}

SVN_ROOT="$APP/Contents/Resources/svn"
if [[ -d "$SVN_ROOT" ]]; then
  echo "== signing nested runtime inside-out"
  # Dylibs first: every parent's signature covers the bytes of its children.
  if compgen -G "$SVN_ROOT/lib/*.dylib" >/dev/null; then
    for lib in "$SVN_ROOT"/lib/*.dylib; do
      sign_one "$lib"
    done
    echo "   $(find "$SVN_ROOT/lib" -name '*.dylib' | wc -l | tr -d ' ') dylib(s)"
  fi
  for tool in "$SVN_ROOT"/bin/*; do
    [[ -f "$tool" ]] || continue
    sign_one "$tool"
    echo "   $(basename "$tool")"
  done
fi

# The signature lives inside each Mach-O, so the manifest written before signing
# no longer describes these bytes. Re-measure now — before the app is sealed —
# because the app's signature covers this file too: rewriting it afterwards would
# invalidate the app signature we just made.
if [[ -f "$APP/Contents/Resources/licenses/runtime-manifest.json" ]]; then
  echo "== re-measuring the runtime manifest"
  "$ROOT/scripts/bundle-svn-runtime.sh" --refresh-manifest "$APP" | sed 's/^/   /'
fi

echo "== signing the app"
# `--entitlements` applies to the main executable. The file is intentionally
# empty; see packaging/macos/entitlements.plist for why nothing is requested.
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP" \
  || { echo "error: signing the app failed" >&2; exit 1; }

echo "== verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/   /'

DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1)"
if grep -q "flags=.*runtime" <<< "$DETAILS"; then
  echo "   hardened runtime: on"
else
  echo "error: hardened runtime flag missing from the app signature" >&2
  echo "$DETAILS" | sed 's/^/   /' >&2
  exit 1
fi

AUTHORITY="$(sed -n 's/^Authority=//p' <<< "$DETAILS" | head -1)"
echo "   authority: ${AUTHORITY:-unknown}"

# `spctl` passes here for a development certificate on the machine that owns it,
# so a pass is not proof of notarisation. The real check is `stapler validate`
# after submitting, which is packaging/macos/notarize.sh's job.
if spctl --assess --type execute "$APP" >/dev/null 2>&1; then
  echo "   Gatekeeper assessment: accepted on this machine (local trust only)"
else
  echo "   Gatekeeper assessment: rejected until the ticket is stapled (see packaging/macos/notarize.sh)"
fi

if [[ "$SHIPPABLE" -eq 1 ]]; then
  echo "== signed $APP for distribution"
else
  echo "== signed $APP for local use only (development identity; not notarisable)"
fi
