#!/usr/bin/env bash
# F12 act: try to check out from the too-new repository.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
run_capture checkout "$SVN" checkout \
    "file://$SCENARIO_WORK/repo-newer/trunk" "$SCENARIO_WORK/wc-too-new" \
    --non-interactive --no-auth-cache

echo "checkout exited $(capture_exit checkout)"
