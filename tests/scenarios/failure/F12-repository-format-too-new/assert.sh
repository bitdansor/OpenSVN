#!/usr/bin/env bash
# F12 assert: refused for the right reason, nothing half-created, repository not
# "helpfully" upgraded.
set -uo pipefail
source "${SCENARIO_ROOT:?}/tests/scenarios/lib.sh"

BAD_REPO="$SCENARIO_WORK/repo-newer"
err=$(capture_err checkout)

assert_failed checkout
assert_contains "$err" "E160043" "the real cause token"
assert_contains "$err" "E170013" "the misleading symptom token really is present"

# Symptom before cause is the bug this scenario exists for.
assert_classified_as checkout SVN-0007
assert_contains "$(probe_field checkout remediation)" "不会自动升级仓库" "remediation states that nothing will be upgraded"

# No half-built working copy left behind.
assert_file_absent "$SCENARIO_WORK/wc-too-new" "checkout destination"

# R5: never auto-upgrade a repository. This is destructive and irreversible, so
# it is asserted on the repository's own bytes rather than trusted.
assert_eq "$(head -1 "$BAD_REPO/db/format")" "$(cat "$STATE/format.before")" "repository format untouched"

# Control: the same svn still checks out a healthy repository, so the refusal is
# about the format and not about a broken harness.
run_capture checkout-good "$SVN" checkout "$REPO_URL/trunk" "$SCENARIO_WORK/wc-good" \
    --non-interactive --no-auth-cache
assert_succeeded checkout-good

echo "ok: too-new repository → SVN-0007, no auto-upgrade, healthy checkout unaffected"
