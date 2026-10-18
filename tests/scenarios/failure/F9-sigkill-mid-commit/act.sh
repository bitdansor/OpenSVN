#!/usr/bin/env bash
# F9 act: kill -9 the client once the pre-commit hook is running.
#
# This stage starts the commit by hand instead of using run_capture, because it
# has to kill the very process it started.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
WC="$SCENARIO_WORK/wc"

"$SVN" commit "$WC" -m "会被中断的提交" --non-interactive --no-auth-cache \
    > "$STATE/commit.out" 2> "$STATE/commit.err" &
client=$!
echo "$client" > "$STATE/client.pid"

i=0
while (( i < 150 )); do
    [[ -e "$STATE/hook-started" ]] && break
    sleep 0.1
    i=$((i + 1))
done
if [[ ! -e "$STATE/hook-started" ]]; then
    echo "pre-commit hook never ran: the commit did not reach the server" >&2
    kill -9 "$client" 2>/dev/null
    exit 1
fi

kill -9 "$client" 2>/dev/null
hook=$(cat "$STATE/hook.pid" 2>/dev/null)
if [[ -n "$hook" ]]; then
    kill -9 "$hook" 2>/dev/null
fi

wait "$client" 2>/dev/null
echo "$?" > "$STATE/commit.exit"
echo "killed the client mid-commit, exit=$(cat "$STATE/commit.exit")"
