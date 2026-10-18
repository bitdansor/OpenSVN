#!/usr/bin/env bash
# F11 assert: reported as a permission problem with a remedy that can work.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

WC="$SCENARIO_WORK/wc"
err=$(capture_err commit)

assert_failed commit
assert_contains "$err" "E200031" "sqlite reported a read-only database"

# The whole point: svn prints E155004 first, so a naive mapping says "run
# cleanup" — a command that writes to the same directory and fails identically.
assert_contains "$err" "E155004" "the misleading token really is present"
assert_classified_as commit SVN-0006

remediation=$(probe_field commit remediation)
assert_contains "$remediation" "Cleanup 无法解决只读磁盘" "remediation warns cleanup will not help"
assert_not_contains "$remediation" "先执行 Cleanup" "remediation must not send the user to cleanup"

# Nothing lost, nothing landed.
assert_contains "$(cat "$WC/tracked.txt")" "local edit on a read-only volume" "local change preserved"
assert_eq "$(repo_head)" "$(cat "$STATE/head.before")" "repository head"

# Restore permissions and prove the working copy needs no repair at all.
chmod -R u+w "$WC/.svn"
assert_status_parseable "$WC"
assert_contains "$(xml_items "$STATE/status-wc.xml" modified)" "tracked.txt" "status reports the modification"

echo "ok: read-only .svn → SVN-0006 (not SVN-0004), no data lost"
