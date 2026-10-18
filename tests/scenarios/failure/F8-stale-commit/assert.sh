#!/usr/bin/env bash
# F8 assert: the commit was refused, nothing was lost, and the app says "update
# first" rather than "retry".
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

WC_A="$SCENARIO_WORK/wc-a"
err=$(capture_err commit)

assert_failed commit
assert_contains "$err" "E160028" "svn's own out-of-date token"

# What the app would actually show.
assert_classified_as commit SVN-0202
assert_contains "$(probe_field commit remediation)" "先 Update 再提交" "remediation"
assert_not_contains "$(probe_field commit remediation)" "重试" "remediation must not suggest retrying a stale commit"

# Local work survives: this is the part a hardcoded-stderr unit test cannot prove.
assert_contains "$(cat "$WC_A/tracked.txt")" "a change" "local change preserved"

assert_status_parseable "$WC_A"
assert_contains "$(xml_items "$STATE/status-wc-a.xml" modified)" "tracked.txt" "status still reports the modification"

# The rejected commit left no trace on the server.
assert_eq "$(repo_head)" "$(cat "$STATE/head.before")" "repository head"

echo "ok: refused as SVN-0202, local change intact, head unchanged"
