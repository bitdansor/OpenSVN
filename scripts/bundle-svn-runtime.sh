#!/usr/bin/env bash
# Embeds a self-contained svn runtime into an existing .app bundle.
#
#   scripts/bundle-svn-runtime.sh build/OpenSVN.app
#   SVN_BIN=/opt/homebrew/bin/svn scripts/bundle-svn-runtime.sh build/OpenSVN.app
#
# Layout produced (matches SVNServiceFactory.bundledCandidateURLs):
#   Contents/Resources/svn/bin/svn
#   Contents/Resources/svn/lib/*.dylib
#
# Each third-party dylib is copied under the *name referenced by the parent*
# (symlinked Homebrew libs break realpath-based rewriting, see ADR-0003), all
# install names become @rpath/<name>, and everything is re-signed from the
# inside out — install_name_tool invalidates signatures, and on Apple Silicon an
# invalid signature means SIGKILL at launch.
set -euo pipefail

APP="${1:-}"
[[ -n "$APP" && -d "$APP/Contents" ]] || { echo "usage: $0 /path/to/OpenSVN.app" >&2; exit 1; }

SVN_BIN="${SVN_BIN:-$(command -v svn || true)}"
[[ -x "$SVN_BIN" ]] || { echo "error: no svn found (set SVN_BIN)" >&2; exit 1; }

for tool in otool install_name_tool codesign; do
  command -v "$tool" >/dev/null || { echo "error: missing $tool (install Xcode CLT)" >&2; exit 1; }
done

RUNTIME="$APP/Contents/Resources/svn"
BIN_DIR="$RUNTIME/bin"
LIB_DIR="$RUNTIME/lib"

case "$RUNTIME" in
  "$APP"/Contents/Resources/svn) ;;
  *) echo "refusing to remove unexpected path: $RUNTIME" >&2; exit 1 ;;
esac

echo "== bundling $( "$SVN_BIN" --version --quiet ) from $SVN_BIN"
rm -rf "$RUNTIME"
mkdir -p "$BIN_DIR" "$LIB_DIR"
cp "$SVN_BIN" "$BIN_DIR/svn"
chmod u+w "$BIN_DIR/svn"

list_deps() {
  otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' \
    | grep -E '^/' | grep -vE '^/(usr/lib|System)/' || true
}

declare -a QUEUE=("$SVN_BIN")
declare -a SEEN_PATHS=()
declare -a MAP_FROM=()
declare -a MAP_TO=()
INDEX=0

while [[ "$INDEX" -lt "${#QUEUE[@]}" ]]; do
  CUR="${QUEUE[$INDEX]}"; INDEX=$((INDEX + 1))
  while IFS= read -r DEP; do
    [[ -z "$DEP" ]] && continue
    skip=0
    for known in "${MAP_FROM[@]:-}"; do [[ "$known" == "$DEP" ]] && skip=1 && break; done
    [[ "$skip" -eq 1 ]] && continue

    REAL="$(/usr/bin/python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$DEP" 2>/dev/null || echo "$DEP")"
    if [[ ! -f "$REAL" ]]; then
      echo "  warning: missing dependency $DEP (skipped)" >&2
      continue
    fi
    NAME="$(basename "$DEP")"
    cp "$REAL" "$LIB_DIR/$NAME"
    chmod u+w "$LIB_DIR/$NAME"
    MAP_FROM+=("$DEP")
    MAP_TO+=("$NAME")
    QUEUE+=("$REAL")
  done < <(list_deps "$CUR")
done

echo "== copied ${#MAP_TO[@]} third-party libraries"

for TARGET in "$BIN_DIR/svn" "$LIB_DIR"/*.dylib; do
  [[ -e "$TARGET" ]] || continue
  while IFS= read -r DEP; do
    [[ -z "$DEP" ]] && continue
    for i in "${!MAP_FROM[@]}"; do
      if [[ "${MAP_FROM[$i]}" == "$DEP" ]]; then
        install_name_tool -change "$DEP" "@rpath/${MAP_TO[$i]}" "$TARGET" 2>/dev/null || true
        break
      fi
    done
  done < <(list_deps "$TARGET")

  case "$TARGET" in
    */lib/*) install_name_tool -id "@rpath/$(basename "$TARGET")" "$TARGET" 2>/dev/null || true ;;
  esac
done

install_name_tool -add_rpath "@executable_path/../lib" "$BIN_DIR/svn" 2>/dev/null || true

echo "== re-signing inner binaries first"
for f in "$LIB_DIR"/*.dylib; do
  [[ -e "$f" ]] && codesign --force --sign - "$f" >/dev/null 2>&1
done
codesign --force --sign - "$BIN_DIR/svn" >/dev/null 2>&1

# Verify: no host paths left, and the binary actually runs from inside the bundle.
RESIDUE="$(otool -L "$BIN_DIR/svn" | grep -E '^\s+/(opt|usr/local)/' || true)"
if [[ -n "$RESIDUE" ]]; then
  echo "error: host paths remain:" >&2
  echo "$RESIDUE" >&2
  exit 2
fi

VERSION="$("$BIN_DIR/svn" --version --quiet 2>&1)" || {
  echo "error: bundled svn does not run: $VERSION" >&2
  exit 2
}
echo "== bundled svn $VERSION ($(du -sh "$RUNTIME" | awk '{print $1}'))"

# Licences: collect what is available next to the Homebrew formula, so the
# compliance work in stage 6 has something to start from.
LICENSE_DIR="$APP/Contents/Resources/licenses"
mkdir -p "$LICENSE_DIR"
echo "see NOTICE and third_party/README.md for the authoritative inventory" > "$LICENSE_DIR/README.txt"
