#!/usr/bin/env bash
# F9 arrange: a repository whose pre-commit hook parks long enough for act.sh to
# kill the client mid-transaction.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
make_repo

WC="$SCENARIO_WORK/wc"
checkout "$REPO_URL/trunk" "$WC"
printf 'pending local edit\n' >> "$WC/tracked.txt"

# The hook announces itself, then hangs. act.sh waits for the announcement, so
# the kill lands inside the commit rather than before or after it.
{
    echo '#!/bin/sh'
    echo "echo \$\$ > \"$STATE/hook.pid\""
    echo "touch \"$STATE/hook-started\""
    echo 'sleep 30'
    echo 'exit 0'
} > "$REPO/hooks/pre-commit"
chmod +x "$REPO/hooks/pre-commit"

repo_head > "$STATE/head.before"
echo "arranged: head=$(cat "$STATE/head.before"), hook installed"
