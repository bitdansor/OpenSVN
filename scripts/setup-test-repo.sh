#!/usr/bin/env bash
# Creates a local Subversion repository plus two working copies that cover the
# awkward cases the specs require: Chinese paths, spaces, special characters,
# long paths, text/property/tree conflicts, missing files and repository locks.
#
#   scripts/setup-test-repo.sh            # create/refresh everything
#   scripts/setup-test-repo.sh --serve    # also start svnserve on :3690
#
# Everything lives under tests/.work (git-ignored). Safe to re-run: the script
# only removes that exact directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/tests/.work"
REPO="$WORK/repo"
WC_A="$WORK/wc-a"
WC_B="$WORK/wc-b"
SEED="$WORK/seed"
SERVE=0
[[ "${1:-}" == "--serve" ]] && SERVE=1

SVN="${SVN:-$(command -v svn || true)}"
SVNADMIN="${SVNADMIN:-$(command -v svnadmin || true)}"
if [[ -z "$SVN" || -z "$SVNADMIN" ]]; then
  echo "error: svn / svnadmin not found in PATH" >&2
  exit 1
fi
SVN_VERSION="$("$SVN" --version --quiet)"

# Commits are authored by a fixed account rather than by whoever runs the script:
# the recordings are published, and an OS account name does not belong in them.
# `capture-fixtures.sh` normalises authors too, so this is the cheaper half of a
# belt-and-braces rule rather than the only guard.
AUTHOR=(--username fixture --password fixture --no-auth-cache)

case "$WORK" in
  */tests/.work) ;;
  *) echo "refusing to remove unexpected path: $WORK" >&2; exit 1 ;;
esac

echo "== using svn $SVN_VERSION =="
rm -rf "$WORK"
mkdir -p "$WORK"

"$SVNADMIN" create "$REPO" >/dev/null
REPO_URL="file://$REPO"

# ---------------------------------------------------------------- seed content
mkdir -p "$SEED/trunk/src" "$SEED/trunk/docs" "$SEED/branches" "$SEED/tags"

cat > "$SEED/trunk/README.md" <<'EOF'
# Fixture project

Used by OpenSVN contract tests. Do not edit by hand.
EOF

cat > "$SEED/trunk/src/main.swift" <<'EOF'
func greet() {
    print("hello")
}
EOF

cat > "$SEED/trunk/src/util.swift" <<'EOF'
func add(_ a: Int, _ b: Int) -> Int { a + b }
EOF

# Chinese + space + special characters in one file name.
printf '你好，SVN\n' > "$SEED/trunk/docs/中文 文档 (v1) & notes.txt"
# A deliberately long path (well under the 1024-byte per-component limit).
LONG_DIR="$SEED/trunk/docs/$(printf 'segment-%02d/' 1 2 3 4 5 6 7 8)"
mkdir -p "$LONG_DIR"
echo "long path payload" > "$LONG_DIR/deeply-nested-file-name.txt"
# File that will be deleted later.
echo "temporary" > "$SEED/trunk/docs/to-delete.txt"
# Files that will carry conflicts / a repository lock.
echo "locked content" > "$SEED/trunk/docs/locked.txt"
echo "tree conflict target" > "$SEED/trunk/docs/tree-conflict.txt"
echo "repository lock target" > "$SEED/trunk/docs/repo-locked.txt"

"$SVN" import "$SEED" "$REPO_URL" -m "初始导入：包含中文路径、空格与特殊字符" "${AUTHOR[@]}" >/dev/null

# ------------------------------------------------------------------ work copies
"$SVN" checkout "$REPO_URL/trunk" "$WC_A" --no-auth-cache >/dev/null
"$SVN" checkout "$REPO_URL/trunk" "$WC_B" --no-auth-cache >/dev/null

# 1. modify a tracked file (wc-a keeps it local)
printf '\n// local change A\n' >> "$WC_A/src/main.swift"

# 2. add a new file with a Chinese name
printf 'new file\n' > "$WC_A/docs/新增文件.txt"
"$SVN" add "$WC_A/docs/新增文件.txt" --no-auth-cache >/dev/null

# 3. add an unversioned file (not scheduled)
printf 'not scheduled\n' > "$WC_A/docs/未纳入版本控制.txt"

# 4. schedule a deletion
"$SVN" delete "$WC_A/docs/to-delete.txt" --no-auth-cache >/dev/null

# 5. property modification
"$SVN" propset svn:mime-type "text/plain; charset=utf-8" "$WC_A/src/util.swift" --no-auth-cache >/dev/null
"$SVN" propset custom:owner "培训部" "$WC_A" --no-auth-cache >/dev/null

# 6. text conflict: both sides edit the same file, b commits first.
printf '// B change\n' >> "$WC_B/src/util.swift"
"$SVN" commit "$WC_B" -m "wc-b：修改 util.swift" "${AUTHOR[@]}" >/dev/null
printf '// A change\n' >> "$WC_A/src/util.swift"
"$SVN" update "$WC_A" --non-interactive --no-auth-cache >/dev/null

# 7. property conflict on the directory property set above.
"$SVN" propget custom:owner "$WC_B" >/dev/null 2>&1 || true

# 8. text conflict on locked.txt (both sides changed the same lines).
printf '\n// A edit before delete\n' >> "$WC_A/docs/locked.txt"
printf '\n// B edit\n' >> "$WC_B/docs/locked.txt"
"$SVN" commit "$WC_B" -m "wc-b：提交 locked.txt" "${AUTHOR[@]}" >/dev/null
"$SVN" update "$WC_A" --non-interactive --no-auth-cache >/dev/null || true

# 9. tree conflict: b deletes a file that a has modified locally.
printf '\n// A local edit\n' >> "$WC_A/docs/tree-conflict.txt"
"$SVN" delete "$WC_B/docs/tree-conflict.txt" --no-auth-cache >/dev/null
"$SVN" commit "$WC_B" -m "wc-b：删除 tree-conflict.txt" "${AUTHOR[@]}" >/dev/null
"$SVN" update "$WC_A" --non-interactive --no-auth-cache >/dev/null || true

# 10. repository file lock (requires a username, even over file://).
"$SVN" lock "$WC_B/docs/repo-locked.txt" --username fixture --password fixture \
      -m "fixture lock" --no-auth-cache >/dev/null 2>&1 || true

# 11. a missing file (deleted from disk without svn delete)
rm -f "$WC_A/src/removed-on-disk.swift" 2>/dev/null || true
cp "$WC_A/README.md" "$WC_A/src/temp-copy.swift"
"$SVN" add "$WC_A/src/temp-copy.swift" --no-auth-cache >/dev/null
rm -f "$WC_A/src/temp-copy.swift"

echo "== repository: $REPO"
echo "== working copies: $WC_A , $WC_B"
echo "== svn version: $SVN_VERSION"

if [[ "$SERVE" == "1" ]]; then
  if command -v svnserve >/dev/null; then
    svnserve -d -r "$WORK" --listen-port 3690
    echo "== svnserve listening on svn://127.0.0.1:3690/repo"
  else
    echo "warning: svnserve not found" >&2
  fi
fi
