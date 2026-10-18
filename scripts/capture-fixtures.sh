#!/usr/bin/env bash
# Re-records the XML fixtures used by the contract tests from a freshly created
# local repository. Run scripts/setup-test-repo.sh first (or let this script do
# it). The svn version is written to tests/fixtures/README.md — never edit the
# fixtures by hand, and never mix fixtures from different svn versions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/tests/.work"
FIXTURES="$ROOT/tests/fixtures"
SVN="${SVN:-$(command -v svn)}"

# Must mirror SVNProcessRunner.pinnedEnvironment: fixture bytes are compared
# field-by-field against what the runner produces, so the recording locale has to
# be the same one the app uses.
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8

if [[ ! -d "$WORK/repo" ]]; then
  "$ROOT/scripts/setup-test-repo.sh"
fi

mkdir -p "$FIXTURES"
cd "$WORK"

# A pristine checkout, used for the "clean" expectations.
rm -rf wc-clean
"$SVN" checkout "file://$WORK/repo/trunk" wc-clean --no-auth-cache >/dev/null

"$SVN" status wc-clean --xml > "$FIXTURES/svn-status-clean.xml"
"$SVN" status wc-a --xml > "$FIXTURES/svn-status-conflicted.xml"
"$SVN" status wc-b --xml > "$FIXTURES/svn-status-locked.xml"
"$SVN" status --no-ignore wc-a --xml > "$FIXTURES/svn-status-no-ignore.xml"
"$SVN" log "file://$WORK/repo" --xml -v -l 10 > "$FIXTURES/svn-log.xml"
"$SVN" info wc-a --xml > "$FIXTURES/svn-info-wc.xml"
"$SVN" info "file://$WORK/repo/trunk/src/main.swift" --xml > "$FIXTURES/svn-info-url.xml"
"$SVN" diff wc-a/src/main.swift > "$FIXTURES/svn-diff-text.patch" 2>/dev/null || true

VERSION="$("$SVN" --version --quiet)"
cat > "$FIXTURES/README.md" <<EOF
# Recorded SVN fixtures

All \`.xml\` files in this directory were recorded with:

- \`svn --version --quiet\` = \`$VERSION\`
- macOS, locale pinned to \`LC_ALL=en_US.UTF-8\` / \`LANG=en_US.UTF-8\`, matching the
  environment \`SVNProcessRunner\` hands to every child process. Recording under
  \`LC_ALL=C\` is wrong: svn 1.14 rejects non-ASCII paths with \`E000022\` there, so
  the fixtures would not represent what the app actually produces.
- repository: a local \`file://\` repository created by \`scripts/setup-test-repo.sh\`

| file | produced by | covers |
|---|---|---|
| \`svn-status-clean.xml\` | \`svn status --xml\` on a fresh checkout | no output beyond the target |
| \`svn-status-conflicted.xml\` | \`svn status --xml\` on wc-a | modified / added / deleted / unversioned / missing / text conflict / property change / tree conflict |
| \`svn-status-locked.xml\` | \`svn status --xml\` on wc-b | repository file lock (\`<lock>\`) |
| \`svn-status-no-ignore.xml\` | \`svn status --no-ignore --xml\` | ignored files surfaced explicitly |
| \`svn-log.xml\` | \`svn log --xml -l 10\` | author, date, message, changed paths |
| \`svn-info-wc.xml\` | \`svn info --xml\` in a working copy | wc-info, repository root/uuid, commit |
| \`svn-info-url.xml\` | \`svn info --xml\` on a URL | no wc-info, remote last-changed fields |
| \`svn-diff-text.patch\` | \`svn diff\` on one modified file | unified diff rendering |

Re-record with \`scripts/capture-fixtures.sh\`. Do not hand-edit.
EOF

echo "== fixtures written to $FIXTURES (svn $VERSION)"
ls -1 "$FIXTURES"
