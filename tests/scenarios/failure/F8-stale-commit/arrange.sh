#!/usr/bin/env bash
# F8 arrange: two working copies, one of them about to be stale.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
make_repo

WC_A="$SCENARIO_WORK/wc-a"
WC_B="$SCENARIO_WORK/wc-b"
checkout "$REPO_URL/trunk" "$WC_A"
checkout "$REPO_URL/trunk" "$WC_B"

# wc-b wins the race.
printf 'b change\n' >> "$WC_B/tracked.txt"
"$SVN" commit "$WC_B" -m "wc-b：先提交" --non-interactive --no-auth-cache >/dev/null

# wc-a edits the same file while still based on the previous revision.
printf 'a change\n' >> "$WC_A/tracked.txt"

repo_head > "$STATE/head.before"
echo "arranged: head=$(cat "$STATE/head.before") wc-a status=$("$SVN" status -q "$WC_A" | tr -d '\n')"
