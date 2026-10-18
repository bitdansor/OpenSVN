#!/usr/bin/env bash
# F11 act: commit into a read-only .svn.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
run_capture commit "$SVN" commit "$SCENARIO_WORK/wc" \
    -m "只读磁盘上的提交" --non-interactive --no-auth-cache

echo "commit exited $(capture_exit commit)"
