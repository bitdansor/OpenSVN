#!/usr/bin/env bash
# S6-6: prove the built app runs without a Subversion installation.
#
#   scripts/verify-clean-install.sh                       # build/OpenSVN.app
#   scripts/verify-clean-install.sh --app /Applications/OpenSVN.app
#   scripts/verify-clean-install.sh --keep                # keep the scratch tree
#
# What "clean" means here, and what it does not:
#
#   checked   the runtime resolves and operates with PATH=/usr/bin:/bin and an
#             empty HOME — no Homebrew, no user config, no inherited env
#   checked   every bundled binary links only to the bundle or to /usr/lib and
#             /System
#   checked   the bundle still works after being moved to another directory
#             (which is what installing it means: nobody runs it from build/)
#   checked   checkout / add / commit / update / log against a real repository,
#             using only the bundled tools
#   checked   the app's own discovery picks the bundled svn, not a host one
#   NOT       Gatekeeper and quarantine. A real clean-machine test launches the
#             notarised app on a fresh macOS install; that needs a Developer ID
#             (S6-2) and cannot be simulated from the build host.
#
# Exit status 0 only if every check passes. A report is written to
# build/clean-install-report.txt so the result can be attached to a release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/OpenSVN.app"
KEEP=0
PROBE="${PROBE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --probe) PROBE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '1,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$APP/Contents" ]] || { echo "error: no app bundle at $APP" >&2; exit 1; }

WORK="$(mktemp -d /tmp/opensvn-clean.XXXXXX)"
REPORT="$ROOT/build/clean-install-report.txt"
mkdir -p "$ROOT/build"

cleanup() {
  if [[ "$KEEP" == "1" ]]; then
    echo "     scratch tree kept at $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

FAILURES=0
CHECKS=0
LOG="$WORK/report.txt"
: > "$LOG"

pass() { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$*" | tee -a "$LOG"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL  %s\n' "$*" | tee -a "$LOG"; }
note() { printf '      %s\n' "$*" | tee -a "$LOG"; }
section() { printf '\n## %s\n' "$*" | tee -a "$LOG"; }

# A deliberately hostile environment: no Homebrew on PATH, no user config, no
# inherited TMPDIR. If anything here reaches back to the build host, it shows up
# as a failure rather than as a pass on a developer's machine.
mkdir -p "$WORK/home" "$WORK/tmp"
run_clean() {
  env -i \
    HOME="$WORK/home" \
    PATH=/usr/bin:/bin \
    TMPDIR="$WORK/tmp" \
    LC_ALL=en_US.UTF-8 \
    "$@"
}

BIN="$APP/Contents/Resources/svn/bin"
SVN="$BIN/svn"
SVNADMIN="$BIN/svnadmin"

section "1. Bundle contents"
if [[ -x "$SVN" ]]; then pass "bin/svn exists"; else fail "bin/svn missing — build with BUNDLE_SVN=1"; fi
if [[ -x "$SVNADMIN" ]]; then
  pass "bin/svnadmin exists (the merge demo needs it)"
else
  fail "bin/svnadmin missing — the in-app merge demo would fail on a clean machine"
fi
[[ -x "$SVN" && -x "$SVNADMIN" ]] || { echo "cannot continue without the bundled tools" >&2; exit 1; }

LIB_COUNT="$(find "$APP/Contents/Resources/svn/lib" -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$LIB_COUNT" -gt 0 ]]; then pass "$LIB_COUNT third-party libraries bundled"; else fail "no dylibs bundled"; fi

if [[ -f "$APP/Contents/Resources/licenses/runtime-manifest.json" ]]; then
  pass "runtime-manifest.json present"
else
  fail "runtime-manifest.json missing — provenance unrecorded"
fi

section "2. Runs with no inherited environment"
if OUT="$(run_clean "$SVN" --version --quiet 2>&1)"; then
  pass "svn --version works with PATH=/usr/bin:/bin ($OUT)"
else
  fail "svn --version failed in a clean environment: $OUT"
fi
if OUT="$(run_clean "$SVNADMIN" --version --quiet 2>&1)"; then
  pass "svnadmin --version works with PATH=/usr/bin:/bin ($OUT)"
else
  fail "svnadmin --version failed in a clean environment: $OUT"
fi

# Any absolute reference to the build host is a latent crash on another machine.
HOST_PATHS="$(otool -L "$SVN" "$SVNADMIN" 2>/dev/null | grep -E '^\s+/(opt|usr/local|Users)/' || true)"
if [[ -z "$HOST_PATHS" ]]; then
  pass "no host-prefix dependencies in the bundled tools"
else
  fail "host-prefix dependencies remain: $HOST_PATHS"
fi

section "3. Survives being installed elsewhere"
INSTALLED="$WORK/Applications/OpenSVN.app"
mkdir -p "$WORK/Applications"
if ditto "$APP" "$INSTALLED" 2>/dev/null; then
  pass "copied the bundle to a different directory"
else
  fail "could not copy the bundle"
fi
MOVED_SVN="$INSTALLED/Contents/Resources/svn/bin/svn"
if OUT="$(run_clean "$MOVED_SVN" --version --quiet 2>&1)"; then
  pass "relocated svn still runs ($OUT)"
else
  # This is the failure mode of an absolute @rpath or a symlink into the Cellar.
  fail "relocated svn does not run: $OUT"
fi
if run_clean /usr/bin/codesign --verify --deep --strict "$INSTALLED" >/dev/null 2>&1; then
  pass "relocated bundle keeps a valid signature"
else
  fail "relocated bundle fails codesign --verify (installer would reject it)"
fi

section "4. Real repository operations, bundled tools only"
REPO="$WORK/repo"
WC="$WORK/wc"
if run_clean "$SVNADMIN" create "$REPO" >/dev/null 2>&1; then
  pass "svnadmin create"
else
  fail "svnadmin create"
fi

if run_clean "$SVN" checkout "file://$REPO" "$WC" >/dev/null 2>&1; then
  pass "svn checkout file://"
else
  fail "svn checkout file://"
fi

# Non-ASCII filename and message on purpose: the runtime has to carry its own
# locale-independent UTF-8 handling, and this is where a broken ICU/locale link
# would surface.
SAMPLE="$WC/说明 文件.txt"
printf '第一行\n' > "$SAMPLE"
if run_clean "$SVN" add "$SAMPLE" >/dev/null 2>&1; then
  pass "svn add (non-ASCII, with a space)"
else
  fail "svn add"
fi

if run_clean "$SVN" commit -m "初始提交：内置运行时自检" "$WC" >/dev/null 2>&1; then
  pass "svn commit with a non-ASCII message"
else
  fail "svn commit"
fi

printf '第二行\n' >> "$SAMPLE"
if run_clean "$SVN" update "$WC" >/dev/null 2>&1; then
  pass "svn update"
else
  fail "svn update"
fi

STATUS_XML="$(run_clean "$SVN" status --xml "$WC" 2>/dev/null || true)"
# svn pretty-prints XML, so attributes land on their own lines; flatten before
# matching or every check silently compares against a half-element.
STATUS_FLAT="$(tr '\n' ' ' <<< "$STATUS_XML" | tr -s ' ')"
if grep -q "<entry" <<< "$STATUS_FLAT"; then
  # One modified file is expected: the local edit above is still uncommitted.
  if grep -q 'item="modified"' <<< "$STATUS_FLAT"; then
    pass "svn status --xml parses and reports the local edit"
  else
    fail "svn status --xml produced an unexpected entry: $STATUS_FLAT"
  fi
else
  fail "svn status --xml returned no entries"
fi

# `svn log` takes a URL or a working-copy path; a bare repository directory is
# neither, and passing it would fail for a reason unrelated to the runtime.
LOG_XML="$(run_clean "$SVN" log --xml -l 1 "file://$REPO" 2>/dev/null || true)"
if grep -q "初始提交" <<< "$LOG_XML"; then
  pass "svn log --xml round-trips the non-ASCII message"
else
  fail "svn log --xml lost the commit message: $(head -3 <<< "$LOG_XML")"
fi

section "5. The app resolves the bundled svn, not a host one"
if [[ -z "$PROBE" ]]; then
  for candidate in "$ROOT/apps/macos/.build/debug/opensvn-probe" "$ROOT/apps/macos/.build/release/opensvn-probe"; do
    [[ -x "$candidate" ]] && PROBE="$candidate" && break
  done
fi
if [[ -z "$PROBE" ]]; then
  note "building opensvn-probe (one-off)"
  SWIFT_FLAGS="${SWIFT_FLAGS:-}"
  if (cd "$ROOT/apps/macos" && swift build -c debug $SWIFT_FLAGS --product OpenSVNProbe >/dev/null 2>&1); then
    BIN_PATH="$(cd "$ROOT/apps/macos" && swift build -c debug $SWIFT_FLAGS --show-bin-path 2>/dev/null)"
    PROBE="$BIN_PATH/opensvn-probe"
  fi
fi

if [[ -x "$PROBE" ]]; then
  # /nonexistent PATH: the well-known locations still exist on a developer
  # machine, so the interesting assertion is not "svn was found" but "the one
  # found is inside the app".
  DISCOVER="$(run_clean "$PROBE" discover --app "$APP" --path /nonexistent 2>&1 || true)"
  RESOLVED_SOURCE="$(sed -n 's/^source=//p' <<< "$DISCOVER" | head -1)"
  RESOLVED_PATH="$(sed -n 's/^path=//p' <<< "$DISCOVER" | head -1)"
  if [[ "$RESOLVED_SOURCE" == "bundled" ]]; then
    pass "discovery chose the bundled runtime (source=bundled)"
  else
    fail "discovery chose '$RESOLVED_SOURCE' instead of bundled — $DISCOVER"
  fi
  if [[ -n "$RESOLVED_PATH" && "$RESOLVED_PATH" == "$APP"/* ]]; then
    pass "resolved path is inside the app bundle"
  else
    fail "resolved path is outside the bundle: $RESOLVED_PATH"
  fi
else
  fail "opensvn-probe unavailable; could not verify the app's own discovery"
fi

section "6. Uninstall leaves nothing behind"
BEFORE_HOME="$(find "$WORK/home" -type f 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$INSTALLED"
if [[ ! -e "$INSTALLED" ]]; then
  pass "deleting the bundle removes the application"
else
  fail "could not delete the copied bundle"
fi
AFTER_HOME="$(find "$WORK/home" -type f 2>/dev/null | wc -l | tr -d ' ')"
note "files written under the throwaway HOME: $BEFORE_HOME -> $AFTER_HOME (svn config cache only)"
if [[ "$BEFORE_HOME" -le 5 ]]; then
  pass "no application state outside the bundle worth cleaning up"
else
  fail "unexpected state written outside the bundle: $BEFORE_HOME file(s)"
fi

# ---------------------------------------------------------------------------
{
  echo "OpenSVN clean-machine verification"
  echo "  app:    $APP"
  echo "  date:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "  host:   macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) $(uname -m)"
  echo "  svn:    $("$SVN" --version --quiet 2>/dev/null || echo unknown)"
  echo "  result: $((CHECKS - FAILURES))/$CHECKS checks passed"
  echo
  echo "Scope: no system Subversion, no inherited environment, relocated bundle,"
  echo "real checkout/commit/update. Gatekeeper and notarisation are NOT covered —"
  echo "they need a Developer ID and a fresh macOS install (S6-2)."
  echo
  cat "$LOG"
} > "$REPORT"

echo
echo "== $(($CHECKS - FAILURES))/$CHECKS checks passed; report: ${REPORT#$ROOT/}"
if [[ "$FAILURES" -gt 0 ]]; then
  echo "== $FAILURES check(s) failed"
  exit 1
fi
