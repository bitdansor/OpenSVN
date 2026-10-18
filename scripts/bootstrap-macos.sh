#!/usr/bin/env bash
# One-command environment check for macOS development (execution plan S1-8).
#
#   scripts/bootstrap-macos.sh              # check only, never installs
#   scripts/bootstrap-macos.sh --install    # install missing pieces via Homebrew
#
# Design rules:
#   * No sudo. If something genuinely needs root, print the command and exit.
#   * Never modify the user's shell profile or existing svn installation.
#   * Exit non-zero only when a *required* piece is missing; optional pieces warn.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

MIN_MACOS_MAJOR=14
MIN_SVN_MAJOR=1
MIN_SVN_MINOR=8

fail=0
warn=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
miss() { printf '  \033[31mmissing\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; warn=$((warn + 1)); }

section() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
section "System"
# ---------------------------------------------------------------------------
macos_version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
macos_major="${macos_version%%.*}"
if (( macos_major >= MIN_MACOS_MAJOR )); then
  ok "macOS $macos_version (>= ${MIN_MACOS_MAJOR}.0 required)"
else
  miss "macOS $macos_version is below the ${MIN_MACOS_MAJOR}.0 deployment target (ADR-0004)"
fi

case "$(uname -m)" in
  arm64) ok "architecture arm64 (Apple silicon)" ;;
  x86_64) note "architecture x86_64 — supported, but the release pipeline builds universal binaries" ;;
  *) note "unknown architecture $(uname -m)" ;;
esac

# ---------------------------------------------------------------------------
section "Xcode / Swift 6"
# ---------------------------------------------------------------------------
if xcode-select -p >/dev/null 2>&1; then
  devdir="$(xcode-select -p)"
  ok "developer directory: $devdir"
  if [[ "$devdir" == *"CommandLineTools"* ]]; then
    note "only Command Line Tools are selected; the SwiftUI app needs a full Xcode install"
    echo "        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi
else
  miss "no Xcode developer directory — install Xcode 16 or newer from the App Store"
fi

if command -v swift >/dev/null 2>&1; then
  swift_version="$(swift --version 2>/dev/null | head -1)"
  ok "$swift_version"
  if [[ "$swift_version" == *"Swift version 6"* ]]; then
    ok "Swift 6 language mode available"
  else
    miss "Swift 6 toolchain required (docs/development/toolchain.md)"
  fi
else
  miss "swift not on PATH"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  ok "$(xcodebuild -version 2>/dev/null | head -1)"
else
  note "xcodebuild not available — swift build still works, the Xcode project does not"
fi

# ---------------------------------------------------------------------------
section "Subversion CLI"
# ---------------------------------------------------------------------------
if command -v svn >/dev/null 2>&1; then
  svn_version="$(svn --version --quiet 2>/dev/null)"
  svn_major="${svn_version%%.*}"
  svn_rest="${svn_version#*.}"
  svn_minor="${svn_rest%%.*}"
  if (( svn_major > MIN_SVN_MAJOR || (svn_major == MIN_SVN_MAJOR && svn_minor >= MIN_SVN_MINOR) )); then
    ok "svn $svn_version at $(command -v svn)"
  else
    miss "svn $svn_version is below the required ${MIN_SVN_MAJOR}.${MIN_SVN_MINOR}"
  fi
  if (( MIN_SVN_MAJOR == 1 && svn_minor <= 9 )); then
    note "svn < 1.10 has no --password-from-stdin; OpenSVN would have to fall back to an askpass helper"
  fi
else
  miss "svn not on PATH"
  if (( INSTALL )); then
    echo "        installing subversion via Homebrew"
    brew install subversion
  else
    echo "        re-run with --install, or: brew install subversion"
  fi
fi

if command -v svnadmin >/dev/null 2>&1; then
  ok "svnadmin $(svnadmin --version --quiet) (needed to build test repositories)"
else
  note "svnadmin not available — scripts/setup-test-repo.sh will not run"
fi

# ---------------------------------------------------------------------------
section "Tooling"
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  ok "python3 $(python3 --version 2>/dev/null | awk '{print $2}') (scripts/verify-release.py)"
else
  note "python3 not found — scripts/verify-release.py cannot run"
fi

if command -v brew >/dev/null 2>&1; then
  ok "Homebrew at $(command -v brew)"
else
  note "Homebrew not found — only needed to install svn automatically"
fi

# The repository's own build helpers must stay executable.
for script in build-macos-app.sh setup-test-repo.sh capture-fixtures.sh bundle-svn-runtime.sh; do
  if [[ -x "$ROOT/scripts/$script" ]]; then
    ok "scripts/$script is executable"
  else
    note "scripts/$script is not executable — run: chmod +x scripts/$script"
  fi
done

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------
if (( fail > 0 )); then
  printf '\033[31m%d required item(s) missing\033[0m, %d warning(s).\n' "$fail" "$warn"
  exit 1
fi

printf '\033[32mEnvironment looks good\033[0m (%d warning(s)).\n' "$warn"
cat <<'EOF'

Next:
  cd apps/macos && swift build
  cd apps/macos && swift test
  scripts/setup-test-repo.sh          # local repo + conflict working copies
  scripts/build-macos-app.sh          # build/OpenSVN.app
EOF
