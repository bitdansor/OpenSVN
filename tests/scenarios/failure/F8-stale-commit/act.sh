#!/usr/bin/env bash
# F8 act: commit from the stale working copy. Failure is the expected outcome,
# so it is captured rather than allowed to abort the stage.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
run_capture commit "$SVN" commit "$SCENARIO_WORK/wc-a" \
    -m "wc-a：过期提交" --non-interactive --no-auth-cache

echo "commit exited $(capture_exit commit)"
