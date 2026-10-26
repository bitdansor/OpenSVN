#!/usr/bin/env bash
# Re-records the XML fixtures used by the contract tests from a freshly created
# local repository. Run scripts/setup-test-repo.sh first (or let this script do
# it). The svn version is written to testdata/README.md — never edit the
# fixtures by hand, and never mix fixtures from different svn versions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/tests/.work"
FIXTURES="$ROOT/testdata"
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

# --------------------------------------------------------------- normalisation
# The recorded bytes carry two pieces of the capturing machine: the absolute path
# of the work tree, which contains the developer's home directory, and the
# author of every commit, which is the OS account name. Neither belongs in a
# published fixture, and both make the bytes differ per machine. They are
# rewritten to fixed values so re-recording anywhere produces the same files and
# the test targets have one constant to match.
CANONICAL_ROOT="/private/tmp/opensvn-fixtures"
CANONICAL_AUTHOR="fixture"

python3 - "$FIXTURES" "$WORK" "$CANONICAL_ROOT" "$CANONICAL_AUTHOR" <<'PY'
import getpass
import pathlib
import sys

fixtures, work, canonical_root, canonical_author = sys.argv[1:5]
# `$WORK` may be reached through a symlink; normalise whichever form was recorded.
roots = {work, str(pathlib.Path(work).resolve())}
account = getpass.getuser()

for path in sorted(pathlib.Path(fixtures).glob("*.xml")):
    text = path.read_text(encoding="utf-8")
    rewritten = text.replace(f"<author>{account}</author>", f"<author>{canonical_author}</author>")
    for root in roots:
        rewritten = rewritten.replace(root, canonical_root)
    if rewritten != text:
        path.write_text(rewritten, encoding="utf-8")
        print(f"  normalised {path.name}")
PY

VERSION="$("$SVN" --version --quiet)"
cat > "$FIXTURES/README.md" <<EOF
# Recorded SVN fixtures

The recorded \`.xml\` fixtures in this directory share one environment:

- \`svn --version --quiet\` = \`$VERSION\`
- macOS, locale pinned to \`LC_ALL=en_US.UTF-8\` / \`LANG=en_US.UTF-8\`, matching the
  environment \`SVNProcessRunner\` hands to every child process. Recording under
  \`LC_ALL=C\` is wrong: svn 1.14 rejects non-ASCII paths with \`E000022\` there, so
  the fixtures would not represent what the app actually produces.
- repository: a local \`file://\` repository created by \`scripts/setup-test-repo.sh\`
- paths and authors are normalised: the work tree's absolute path becomes
  \`$CANONICAL_ROOT\`, and the capturing account's name becomes
  \`$CANONICAL_AUTHOR\`. A fixture must never contain a real home directory or
  account name, and re-recording on another machine must produce the same bytes.

| file | produced by | covers |
|---|---|---|
| \`svn-status-clean.xml\` | \`svn status --xml\` on a fresh checkout | no output beyond the target |
| \`svn-status-conflicted.xml\` | \`svn status --xml\` on wc-a | modified / added / deleted / unversioned / missing / text conflict / property change / tree conflict |
| \`svn-status-locked.xml\` | \`svn status --xml\` on wc-b | repository file lock (\`<lock>\`) |
| \`svn-status-no-ignore.xml\` | \`svn status --no-ignore --xml\` | ignored files surfaced explicitly |
| \`svn-status-remote-changes.xml\` | \`svn status --xml -u\` | incoming add / modify / delete, with the revision they are compared against (\`<against>\`) |
| \`svn-status-remote-lock.xml\` | hand-written | own lock, another user's lock and no lock in one snapshot — \`<lock>\` under \`wc-status\` is mine, under \`repos-status\` is theirs |
| \`svn-log.xml\` | \`svn log --xml -l 10\` | author, date, message, changed paths |
| \`svn-info-wc.xml\` | \`svn info --xml\` in a working copy | wc-info, repository root/uuid, commit |
| \`svn-info-url.xml\` | \`svn info --xml\` on a URL | no wc-info, remote last-changed fields |
| \`svn-info-conflict.xml\` | \`svn info --xml\` on a text-conflicted file | \`<conflict>\` block: \`prev-base-file\`, \`prev-wc-file\`, \`source-left\` / \`source-right\` revisions — the three versions the merge editor needs |
| \`svn-diff-text.patch\` | \`svn diff\` on one modified file | unified diff rendering |

Re-record with \`scripts/capture-fixtures.sh\`. Do not hand-edit otherwise: a
fixture and the tests that read it have to agree, and a quiet edit breaks that
agreement without breaking the build.

\`svn-status-remote-changes.xml\`, \`svn-status-remote-lock.xml\` and
\`svn-info-conflict.xml\` are not produced by that script — an inbound commit, a
lock held by another user and a conflicted merge each need a second working copy
or a second identity, which it does not set up. They are edited by hand when the
contract changes, and when they are, they use the same \`$CANONICAL_ROOT\` path
and \`$CANONICAL_AUTHOR\` author as the recorded ones. Keep their rows in the
script's template too: it rewrites this file from a heredoc, so a row that only
lives here disappears on the next recording.
EOF

echo "== fixtures written to $FIXTURES (svn $VERSION)"
ls -1 "$FIXTURES"
