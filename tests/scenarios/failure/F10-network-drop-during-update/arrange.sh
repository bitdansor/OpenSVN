#!/usr/bin/env bash
# F10 arrange: a served repository, a proxy in front of it, and a working copy
# checked out through the proxy so its URL survives the fault.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
make_repo

WC_ADMIN="$SCENARIO_WORK/wc-admin"
WC="$SCENARIO_WORK/wc"

# A file large enough that the update has to move more bytes than the proxy's
# budget, so the cut cannot land outside the transfer.
#
# The content is pseudo-random rather than repeated filler on purpose: svn
# compresses the wire protocol, and 1 MB of "xxxx…" squeezes below the cut
# threshold, which made the first version of this scenario pass vacuously with a
# fully successful update. A fixed seed keeps it reproducible.
checkout "$REPO_URL/trunk" "$WC_ADMIN"
"$PYTHON" - "$WC_ADMIN/payload.txt" 12000 v1 <<'PY'
import random, sys
path, lines, marker = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rng = random.Random(f"{marker}-seed")
with open(path, "w", encoding="utf-8") as handle:
    for index in range(lines):
        handle.write(f"{marker}-{index:05d} {rng.getrandbits(128):032x}\n")
PY
"$SVN" add "$WC_ADMIN/payload.txt" --no-auth-cache --non-interactive >/dev/null
"$SVN" commit "$WC_ADMIN" -m "加入 payload v1" --no-auth-cache --non-interactive >/dev/null

SERVE_PORT=$(free_port)
PROXY_PORT=$(free_port)
start_svnserve "$SCENARIO_WORK" "$SERVE_PORT"
start_proxy "$PROXY_PORT" "$SERVE_PORT" 0

echo "$SERVE_PORT" > "$STATE/serve.port"
echo "$PROXY_PORT" > "$STATE/proxy.port"

checkout "svn://127.0.0.1:$PROXY_PORT/repo/trunk" "$WC"

# Now push a much larger revision: the pending update is what act.sh interrupts.
"$PYTHON" - "$WC_ADMIN/payload.txt" 24000 v2 <<'PY'
import random, sys
path, lines, marker = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rng = random.Random(f"{marker}-seed")
with open(path, "w", encoding="utf-8") as handle:
    for index in range(lines):
        handle.write(f"{marker}-{index:05d} {rng.getrandbits(128):032x}\n")
PY
"$SVN" commit "$WC_ADMIN" -m "把 payload 换成 v2（更大）" --no-auth-cache --non-interactive >/dev/null

wc -c < "$WC/payload.txt" | tr -d " " > "$STATE/size.before"
wc -c < "$WC_ADMIN/payload.txt" | tr -d " " > "$STATE/size.after"
echo "arranged: pending update $(cat "$STATE/size.before") → $(cat "$STATE/size.after") bytes"
