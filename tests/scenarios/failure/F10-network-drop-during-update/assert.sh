#!/usr/bin/env bash
# F10 assert: the update failed for a network reason, nothing was truncated, and
# a retry once the link is back succeeds.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

WC="$SCENARIO_WORK/wc"
PROXY_PORT=$(cat "$STATE/proxy.port")
SERVE_PORT=$(cat "$STATE/serve.port")

# Non-vacuity: the cut has to have happened inside the transfer. Without this,
# an update that failed for an unrelated reason would still pass the rest.
assert_failed update
assert_contains "$(cat "$STATE/proxy-$PROXY_PORT.log")" "byte budget exhausted" "proxy actually cut mid-transfer"
assert_classified_as update SVN-0201
assert_contains "$(probe_field update remediation)" "无法连接服务器" "remediation names the network"

# svn writes a temporary file and renames it, so the visible file must be all-old
# or all-new — never a prefix of the new content.
size=$(wc -c < "$WC/payload.txt" | tr -d ' ')
before=$(cat "$STATE/size.before")
after=$(cat "$STATE/size.after")
if [[ "$size" != "$before" && "$size" != "$after" ]]; then
    fail "payload.txt is $size bytes: neither the old ($before) nor the new ($after) size, so it was left truncated"
fi

# The working copy is still something the app can read.
assert_status_parseable "$WC"
run_capture cleanup "$SVN" cleanup --non-interactive --no-auth-cache "$WC"
assert_succeeded cleanup

# Link restored: the same command must now finish.
stop_pid "$PIDS/proxy-$PROXY_PORT.pid"
start_proxy "$PROXY_PORT" "$SERVE_PORT" 0
run_capture update-retry "$SVN" update "$WC" --non-interactive --no-auth-cache
assert_succeeded update-retry

assert_eq "$(wc -c < "$WC/payload.txt" | tr -d ' ')" "$after" "payload size after a successful retry"
assert_contains "$(cat "$WC/payload.txt")" "v2-00000" "payload holds the new revision"

echo "ok: mid-transfer cut → SVN-0201, no truncation, retry succeeded"
