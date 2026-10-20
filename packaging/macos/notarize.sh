#!/usr/bin/env bash
# Submits the signed app to Apple's notary service, then staples the ticket.
#
#   NOTARY_PROFILE=opensvn-notary packaging/macos/notarize.sh build/OpenSVN.app
#
#   # or, without a stored profile:
#   NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=TEAMID NOTARY_PASSWORD=app-specific-pw \
#     packaging/macos/notarize.sh build/OpenSVN.app
#
# Credentials never touch the repository: either a keychain profile created with
# `xcrun notarytool store-credentials`, or environment variables supplied by CI
# secrets. There is deliberately no flag that reads a password from a file.
#
# Order matters and is easy to get wrong: notarise the *zip*, staple the *app*,
# then validate. Stapling before the ticket exists does nothing, and shipping the
# pre-staple zip means the first launch of an offline install still fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${1:-$ROOT/build/OpenSVN.app}"

[[ -d "$APP/Contents" ]] || { echo "error: no app bundle at $APP" >&2; exit 1; }

if ! xcrun -f notarytool >/dev/null 2>&1; then
  echo "error: notarytool not found (needs Xcode 13+ or the Command Line Tools)" >&2
  exit 1
fi

# A development certificate produces a signature Apple will not accept. Saying so
# here costs one line; discovering it after a 5-minute upload costs a release.
DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
AUTHORITY="$(sed -n 's/^Authority=//p' <<< "$DETAILS" | head -1)"
case "$AUTHORITY" in
  "Developer ID Application:"*) ;;
  *)
    echo "error: not notarisable — signed by '${AUTHORITY:-nothing}'" >&2
    echo "       notarisation requires a Developer ID Application signature." >&2
    echo "       Run scripts/sign-macos-app.sh with a Developer ID identity first." >&2
    exit 1
    ;;
esac

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  CREDENTIALS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
else
  cat >&2 <<'MSG'
error: no notary credentials.

  Either create a keychain profile once:

    xcrun notarytool store-credentials opensvn-notary \
      --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

  and run with NOTARY_PROFILE=opensvn-notary, or pass NOTARY_APPLE_ID,
  NOTARY_TEAM_ID and NOTARY_PASSWORD in the environment (CI secrets).

  The password is an app-specific password from appleid.apple.com, not the
  account password.
MSG
  exit 1
fi

WORK="$(mktemp -d /tmp/opensvn-notary.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/$(basename "$APP" .app).zip"

echo "== packaging $APP for submission"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== submitting to Apple (this usually takes a few minutes)"
set +e
SUBMIT_OUTPUT="$(xcrun notarytool submit "$ZIP" "${CREDENTIALS[@]}" --wait --timeout 45m 2>&1)"
SUBMIT_STATUS=$?
set -e
echo "$SUBMIT_OUTPUT" | sed 's/^/   /'

SUBMISSION_ID="$(sed -n 's/^ *id: //p' <<< "$SUBMIT_OUTPUT" | head -1)"

if [[ $SUBMIT_STATUS -ne 0 ]] || ! grep -qE "status: Accepted" <<< "$SUBMIT_OUTPUT"; then
  echo "error: notarisation did not succeed" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "== fetching the rejection log" >&2
    xcrun notarytool log "$SUBMISSION_ID" "${CREDENTIALS[@]}" 2>&1 | sed 's/^/   /' >&2 || true
  fi
  exit 1
fi

echo "== stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "== Gatekeeper assessment"
if spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/   /'; then
  echo "== notarised and stapled: $APP"
else
  echo "error: Gatekeeper still rejects the app after stapling" >&2
  exit 1
fi

if [[ -n "${NOTARY_SUMMARY:-}" ]]; then
  /usr/bin/python3 - "$NOTARY_SUMMARY" "$APP" "$SUBMISSION_ID" "$AUTHORITY" <<'PY'
import datetime, json, sys

path, app, submission, authority = sys.argv[1:5]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "app": app,
        "signed": True,
        "notarized": True,
        "authority": authority,
        "submissionId": submission,
        "checkedAt": datetime.datetime.now(datetime.timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ"),
    }, handle, indent=2)
    handle.write("\n")
PY
fi
