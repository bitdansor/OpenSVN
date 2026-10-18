#!/usr/bin/env bash
# F10 act: swap the transparent proxy for one that severs the connection after
# 128 KiB, then update through it.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
WC="$SCENARIO_WORK/wc"
PROXY_PORT=$(cat "$STATE/proxy.port")
SERVE_PORT=$(cat "$STATE/serve.port")

stop_pid "$PIDS/proxy-$PROXY_PORT.pid"
start_proxy "$PROXY_PORT" "$SERVE_PORT" 131072

run_capture update "$SVN" update "$WC" --non-interactive --no-auth-cache
echo "update exited $(capture_exit update) after the proxy cut the connection"
