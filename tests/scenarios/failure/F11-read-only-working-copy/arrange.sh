#!/usr/bin/env bash
# F11 arrange: a working copy whose .svn directory cannot be written.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
make_repo

WC="$SCENARIO_WORK/wc"
checkout "$REPO_URL/trunk" "$WC"
printf 'local edit on a read-only volume\n' >> "$WC/tracked.txt"

repo_head > "$STATE/head.before"

# Make only the administration area read-only. Setting the tracked file itself
# read-only proves nothing: commit reads that file and writes .svn.
chmod -R a-w "$WC/.svn"
echo "arranged: .svn is read-only, head=$(cat "$STATE/head.before")"
