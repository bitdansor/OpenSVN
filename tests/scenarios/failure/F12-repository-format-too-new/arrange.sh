#!/usr/bin/env bash
# F12 arrange: a healthy repository plus a copy that claims a future format.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

require_tools
make_repo

BAD_REPO="$SCENARIO_WORK/repo-newer"
rm -rf "$BAD_REPO"
cp -R "$REPO" "$BAD_REPO"
chmod -R u+w "$BAD_REPO"

# `db/format` is the repository's own version marker. 99 is far beyond anything
# svn 1.x understands, which is exactly the "built by a newer client" case.
printf '99\nlayout sharded 1000\n' > "$BAD_REPO/db/format"
head -1 "$BAD_REPO/db/format" > "$STATE/format.before"

echo "arranged: repo-newer/db/format=$(cat "$STATE/format.before")"
