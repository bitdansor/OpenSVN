#!/usr/bin/env bash
# Embeds a self-contained svn runtime into an existing .app bundle.
#
#   scripts/bundle-svn-runtime.sh build/OpenSVN.app
#   SVN_BIN=/opt/homebrew/bin/svn scripts/bundle-svn-runtime.sh build/OpenSVN.app
#
# Layout produced (matches SVNServiceFactory.bundledCandidateURLs):
#   Contents/Resources/svn/bin/svn
#   Contents/Resources/svn/bin/svnadmin
#   Contents/Resources/svn/lib/*.dylib
#   Contents/Resources/licenses/            <- licence texts + runtime-manifest.json
#
# Both tools are bundled. `svnadmin` is not used by normal operations, but the
# in-app "try a three-way merge" demo creates a repository, and
# DemoWorkspace.adminTool() looks for svnadmin next to svn. Bundling only `svn`
# would make that feature fail on a machine without Homebrew — which is exactly
# the machine this bundle exists for.
#
# Each third-party dylib is copied under the *name referenced by the parent*
# (symlinked Homebrew libs break realpath-based rewriting, see ADR-0003), all
# install names become @rpath/<name>, and everything is re-signed from the
# inside out — install_name_tool invalidates signatures, and on Apple Silicon an
# invalid signature means SIGKILL at launch.
set -euo pipefail

# Signing rewrites the Mach-O files (the signature is embedded in them), so any
# hash recorded before signing is wrong afterwards. Rather than let the manifest
# describe bytes that no longer exist, signing calls back into this script to
# re-measure. One file owns the manifest format; nothing else writes it.
if [[ "${1:-}" == "--refresh-manifest" ]]; then
  TARGET="${2:-}"
  [[ -n "$TARGET" && -d "$TARGET/Contents/Resources/svn" ]] || {
    echo "usage: $0 --refresh-manifest /path/to/OpenSVN.app" >&2
    exit 1
  }
  /usr/bin/python3 - "$TARGET/Contents/Resources/svn" \
    "$TARGET/Contents/Resources/licenses/runtime-manifest.json" <<'PY'
import datetime, hashlib, json, os, sys

runtime, manifest_path = sys.argv[1:3]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

for entry in manifest.get("files", []):
    absolute = os.path.join(runtime, entry["path"])
    if not os.path.isfile(absolute):
        sys.exit(f"error: {entry['path']} listed in the manifest but missing from the bundle")
    with open(absolute, "rb") as handle:
        entry["sha256"] = hashlib.sha256(handle.read()).hexdigest()
    entry["bytes"] = os.path.getsize(absolute)

present = {
    os.path.relpath(os.path.join(root, name), runtime)
    for root, _dirs, names in os.walk(runtime)
    for name in names
}
listed = {entry["path"] for entry in manifest.get("files", [])}
if present != listed:
    sys.exit(f"error: manifest and bundle disagree: only-bundled={sorted(present - listed)} "
             f"only-listed={sorted(listed - present)}")

manifest["generatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=False)
    handle.write("\n")
print(f"== re-measured {len(listed)} bundled file(s) after signing")
PY
  exit 0
fi

APP="${1:-}"
[[ -n "$APP" && -d "$APP/Contents" ]] || { echo "usage: $0 /path/to/OpenSVN.app" >&2; exit 1; }

SVN_BIN="${SVN_BIN:-$(command -v svn || true)}"
[[ -x "$SVN_BIN" ]] || { echo "error: no svn found (set SVN_BIN)" >&2; exit 1; }

# Default to the svnadmin sitting next to svn: a Homebrew subversion install
# ships both, and taking them from the same place keeps the versions aligned.
SVNADMIN_BIN="${SVNADMIN_BIN:-$(dirname "$SVN_BIN")/svnadmin}"
[[ -x "$SVNADMIN_BIN" ]] || { echo "error: no svnadmin next to $SVN_BIN (set SVNADMIN_BIN)" >&2; exit 1; }

for tool in otool install_name_tool codesign; do
  command -v "$tool" >/dev/null || { echo "error: missing $tool (install Xcode CLT)" >&2; exit 1; }
done

RUNTIME="$APP/Contents/Resources/svn"
BIN_DIR="$RUNTIME/bin"
LIB_DIR="$RUNTIME/lib"
LICENSE_DIR="$APP/Contents/Resources/licenses"

case "$RUNTIME" in
  "$APP"/Contents/Resources/svn) ;;
  *) echo "refusing to remove unexpected path: $RUNTIME" >&2; exit 1 ;;
esac

echo "== bundling $( "$SVN_BIN" --version --quiet ) from $SVN_BIN"
rm -rf "$RUNTIME"
mkdir -p "$BIN_DIR" "$LIB_DIR"

# tool name -> source path, kept in parallel arrays so the manifest can record
# where every file came from (S7-2 compliance needs provenance, not just bytes).
TOOL_NAMES=()
TOOL_SOURCES=()
for pair in "svn:$SVN_BIN" "svnadmin:$SVNADMIN_BIN"; do
  name="${pair%%:*}"
  source="${pair#*:}"
  cp "$source" "$BIN_DIR/$name"
  chmod u+w "$BIN_DIR/$name"
  TOOL_NAMES+=("$name")
  TOOL_SOURCES+=("$source")
done

list_deps() {
  otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' \
    | grep -E '^/' | grep -vE '^/(usr/lib|System)/' || true
}

# One closure over both tools: svn and svnadmin link the same libraries, and
# listing them twice would only make the dedupe do the work.
declare -a QUEUE=()
for source in "${TOOL_SOURCES[@]}"; do QUEUE+=("$source"); done
declare -a SEEN_PATHS=()
declare -a MAP_FROM=()
declare -a MAP_TO=()
declare -a MAP_SOURCE=()
INDEX=0

while [[ "$INDEX" -lt "${#QUEUE[@]}" ]]; do
  CUR="${QUEUE[$INDEX]}"; INDEX=$((INDEX + 1))
  while IFS= read -r DEP; do
    [[ -z "$DEP" ]] && continue
    skip=0
    for known in "${MAP_FROM[@]:-}"; do [[ "$known" == "$DEP" ]] && skip=1 && break; done
    [[ "$skip" -eq 1 ]] && continue
    for known in "${SEEN_PATHS[@]:-}"; do [[ "$known" == "$DEP" ]] && skip=1 && break; done
    [[ "$skip" -eq 1 ]] && continue

    REAL="$(/usr/bin/python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$DEP" 2>/dev/null || echo "$DEP")"
    if [[ ! -f "$REAL" ]]; then
      echo "  warning: missing dependency $DEP (skipped)" >&2
      continue
    fi
    NAME="$(basename "$DEP")"
    # Two references can reach the same file by different paths (Homebrew's opt
    # symlinks); the copy is keyed by the name the parent asks for, so keep the
    # first one and still record the mapping for every reference.
    if [[ ! -f "$LIB_DIR/$NAME" ]]; then
      cp "$REAL" "$LIB_DIR/$NAME"
      chmod u+w "$LIB_DIR/$NAME"
    fi
    SEEN_PATHS+=("$DEP")
    MAP_FROM+=("$DEP")
    MAP_TO+=("$NAME")
    MAP_SOURCE+=("$REAL")
    QUEUE+=("$REAL")
  done < <(list_deps "$CUR")
done

echo "== copied $(find "$LIB_DIR" -maxdepth 1 -name '*.dylib' | wc -l | tr -d ' ') third-party libraries (${#MAP_FROM[@]} references rewritten)"

for TARGET in "$BIN_DIR"/* "$LIB_DIR"/*.dylib; do
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

for TOOL in "${TOOL_NAMES[@]}"; do
  install_name_tool -add_rpath "@executable_path/../lib" "$BIN_DIR/$TOOL" 2>/dev/null || true
done

echo "== re-signing inner binaries first"
for f in "$LIB_DIR"/*.dylib; do
  [[ -e "$f" ]] && codesign --force --sign - "$f" >/dev/null 2>&1
done
for TOOL in "${TOOL_NAMES[@]}"; do
  codesign --force --sign - "$BIN_DIR/$TOOL" >/dev/null 2>&1
done

# Verify: no host paths left, and each tool actually runs from inside the bundle.
RESIDUE="$(otool -L "$BIN_DIR"/* | grep -E '^\s+/(opt|usr/local)/' || true)"
if [[ -n "$RESIDUE" ]]; then
  echo "error: host paths remain:" >&2
  echo "$RESIDUE" >&2
  exit 2
fi

for TOOL in "${TOOL_NAMES[@]}"; do
  OUTPUT="$("$BIN_DIR/$TOOL" --version --quiet 2>&1)" || {
    echo "error: bundled $TOOL does not run: $OUTPUT" >&2
    exit 2
  }
  echo "== bundled $TOOL $OUTPUT"
done
SVN_VERSION="$("$BIN_DIR/svn" --version --quiet 2>&1)"

# ---------------------------------------------------------------------------
# Licences and provenance
#
# The runtime is 20+ third-party binaries, and ADR-0003 flags libintl (LGPL) as
# the one that actually obliges us to ship texts. Copying whatever Homebrew kept
# next to each formula is best-effort: it is not a substitute for the S7-2 audit,
# but it turns "we should collect licences later" into a machine-checkable
# inventory with a recorded gap list.
# ---------------------------------------------------------------------------
mkdir -p "$LICENSE_DIR"

PROVENANCE_TSV="$(mktemp)"
trap 'rm -f "$PROVENANCE_TSV"' EXIT
for i in "${!TOOL_NAMES[@]}"; do
  printf 'bin/%s\t%s\n' "${TOOL_NAMES[$i]}" "${TOOL_SOURCES[$i]}" >> "$PROVENANCE_TSV"
done
for i in "${!MAP_TO[@]}"; do
  printf 'lib/%s\t%s\n' "${MAP_TO[$i]}" "${MAP_SOURCE[$i]}" >> "$PROVENANCE_TSV"
done

BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x "$candidate" ]] && BREW="$candidate" && break
done

if [[ -z "$BREW" ]]; then
  echo "  warning: Homebrew not found; licence identifiers will be incomplete" >&2
fi

/usr/bin/python3 - "$RUNTIME" "$PROVENANCE_TSV" "$LICENSE_DIR" "$SVN_VERSION" \
  "$SVN_BIN" "$SVNADMIN_BIN" "$BREW" <<'PY'
import datetime, hashlib, json, os, shutil, subprocess, sys

runtime, tsv, license_dir, svn_version, svn_src, admin_src, brew = sys.argv[1:8]

provenance = {}
with open(tsv, encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        rel, source = line.split("\t", 1)
        provenance[rel] = source

files = []
for root, _dirs, names in os.walk(runtime):
    for name in sorted(names):
        absolute = os.path.join(root, name)
        rel = os.path.relpath(absolute, runtime)
        with open(absolute, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        files.append({
            "path": rel,
            "source": provenance.get(rel, "unknown"),
            "bytes": os.path.getsize(absolute),
            "sha256": digest,
        })
files.sort(key=lambda item: item["path"])


def brew_run(*args, timeout=180):
    try:
        completed = subprocess.run(
            [brew, *args], capture_output=True, text=True, timeout=timeout, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return completed.stdout if completed.returncode == 0 else ""


# ---------------------------------------------------------------------------
# Licences
#
# Homebrew bottles increasingly ship without a LICENSE file in the Cellar, so
# "copy whatever is next to the formula" is not enough. The SPDX identifiers in
# `brew info --json=v2` are the reliable signal; the texts are a bonus. Both go
# into the manifest, and whatever is missing is recorded by name — an audit needs
# to see the gap, not a green checkmark that hides it.
# ---------------------------------------------------------------------------
identifiers: dict[str, list[str]] = {}
texts_copied = 0
texts_missing: list[str] = []

if brew:
    formulas = [line.strip() for line in brew_run("deps", "--installed", "subversion").splitlines() if line.strip()]
    formulas.append("subversion")

    try:
        info = json.loads(brew_run("info", "--json=v2", "--installed") or "{}")
    except ValueError:
        info = {}
    by_name = {entry.get("name"): entry for entry in info.get("formulae", [])}

    for formula in formulas:
        entry = by_name.get(formula, {})
        # `licenses` is the modern array field; `license` is the older scalar.
        ids = entry.get("licenses")
        if not ids and entry.get("license"):
            ids = [entry["license"]]
        identifiers[formula] = ids or []

        prefix = brew_run("--prefix", formula).strip()
        copied_for_formula = 0
        if prefix and os.path.isdir(prefix):
            candidates = []
            for root, dirs, names in os.walk(prefix):
                # Cellar layouts bury docs a few levels down; two is enough and
                # stops the walk from scanning an entire keg's share/ tree.
                if root.count(os.sep) - prefix.count(os.sep) >= 2:
                    dirs[:] = []
                for name in names:
                    if name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")):
                        candidates.append(os.path.join(root, name))
            for path in sorted(candidates)[:4]:
                shutil.copyfile(path, os.path.join(license_dir, f"{formula}__{os.path.basename(path)}"))
                copied_for_formula += 1
                texts_copied += 1
        if copied_for_formula == 0:
            texts_missing.append(formula)

missing_identifiers = sorted(name for name, ids in identifiers.items() if not ids)

readme = os.path.join(license_dir, "README.txt")
with open(readme, "w", encoding="utf-8") as handle:
    handle.write("Bundled Subversion runtime — licence inventory\n\n")
    handle.write(f"svn      {svn_version}\n")
    handle.write(f"source   {svn_src}\n")
    handle.write(f"built    {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n\n")
    handle.write("runtime-manifest.json is the authoritative inventory: every file under\n")
    handle.write("Contents/Resources/svn is listed with its origin and SHA-256, and every\n")
    handle.write("Homebrew formula that contributed a library is listed with its SPDX id.\n\n")
    handle.write(f"licence texts copied: {texts_copied}\n")
    handle.write("formulae with no text available: " + (", ".join(texts_missing) or "none") + "\n")
    handle.write("formulae with no SPDX id: " + (", ".join(missing_identifiers) or "none") + "\n\n")
    handle.write("A missing text is a real gap and is listed above rather than glossed over;\n")
    handle.write("see third_party/README.md and ADR-0003. Resolving it is the S7-2 audit.\n")

manifest = {
    "schemaVersion": 1,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "svnVersion": svn_version,
    "tools": {
        "svn": {"source": svn_src, "bundledPath": "bin/svn"},
        "svnadmin": {"source": admin_src, "bundledPath": "bin/svnadmin"},
    },
    "licenses": {
        "formulae": identifiers,
        "textsCopied": texts_copied,
        "textsMissing": texts_missing,
        "identifiersMissing": missing_identifiers,
    },
    "files": files,
}

out = os.path.join(license_dir, "runtime-manifest.json")
with open(out, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=False)
    handle.write("\n")

print(f"== {len(identifiers)} formula(e), {texts_copied} licence text(s); "
      f"{len(texts_missing)} without text, {len(missing_identifiers)} without an id")
print(f"== wrote {len(files)} file(s) to {out}")
PY

du -sh "$RUNTIME"
