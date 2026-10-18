#!/usr/bin/env bash
# F9 assert: the working copy is left locked, reads still work, writes are
# refused until cleanup — and nothing was lost.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

WC="$SCENARIO_WORK/wc"

# 128 + SIGKILL. Anything else means the client was not what got killed.
assert_eq "$(capture_exit commit)" "137" "client exit code (128+SIGKILL)"
assert_file_exists "$STATE/hook-started" "the commit reached the pre-commit hook"

# svn 1.14 does not make `svn status` fail after a killed commit: it exits 0 and
# reports the working copy as locked (an `L` in the third status column). Reads
# keep working; writes are what the lock blocks.
run_capture status-locked "$SVN" status --non-interactive --no-auth-cache "$WC"
assert_succeeded status-locked
assert_status_parseable "$WC"
assert_contains "$(capture_out status-locked)" "  L" "working copy reported as locked"

# Local work survives the kill.
assert_contains "$(cat "$WC/tracked.txt")" "pending local edit" "local change preserved"
assert_contains "$(xml_items "$STATE/status-wc.xml" modified)" "tracked.txt" "status reports the modification"

# The killed commit never landed.
assert_eq "$(repo_head)" "$(cat "$STATE/head.before")" "repository head unchanged by the killed commit"

# The user retries, and the lock is what they hit first.
run_capture retry-after-kill "$SVN" commit "$WC" -m "重试" --non-interactive --no-auth-cache
assert_failed retry-after-kill
assert_contains "$(capture_err retry-after-kill)" "E155004" "lock token on retry"
assert_classified_as retry-after-kill SVN-0004
assert_contains "$(probe_field retry-after-kill remediation)" "Cleanup" "remediation points at Cleanup"

# Cleanup is the correct next step here: the lock lives in a writable wc.db.
run_capture cleanup "$SVN" cleanup --non-interactive --no-auth-cache "$WC"
assert_succeeded cleanup

run_capture recommit "$SVN" commit "$WC" -m "清理后重新提交" --non-interactive --no-auth-cache
assert_succeeded recommit
assert_eq "$(repo_head)" "$(( $(cat "$STATE/head.before") + 1 ))" "repository head after recommit"

echo "ok: locked → SVN-0004 → cleanup → recommit, no local data lost"
