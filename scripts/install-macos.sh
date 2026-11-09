#!/bin/bash

# Installs OpenSVN from a published release without going through Gatekeeper.
#
# Why this exists: a `.zip` downloaded by a browser gets `com.apple.quarantine`,
# and an ad-hoc signed app is then blocked on first launch until someone walks
# through 系统设置 → 隐私与安全性 → 仍要打开. A file fetched by `curl` carries no
# such flag, so an app installed this way simply opens. Nothing here disables
# Gatekeeper or removes protection from anything the user already has.
#
# What it verifies: the SHA-256 of the archive against the release's SHA256SUMS.
# What it cannot verify: the Ed25519 signature on that file — a shell script has
# no Ed25519 verifier, and requiring Xcode would defeat the purpose. So the first
# install trusts TLS to github.com; every update after it is checked against the
# key compiled into the app.
#
#   curl -fsSL https://raw.githubusercontent.com/bitdansor/OpenSVN/main/scripts/install-macos.sh | bash
#
# Options (for running it from a checkout):
#   --prefix DIR     install into DIR instead of /Applications
#   --archive PATH   install a local .zip (with SHA256SUMS beside it) instead of
#                    downloading; also how this script gets tested
#   --version TAG    install a specific tag instead of the latest release
#   --force          replace an existing installation
#   --no-open        do not launch the app afterwards

set -euo pipefail

readonly REPOSITORY="bitdansor/OpenSVN"
readonly APP_NAME="OpenSVN.app"
readonly RELEASES="https://github.com/${REPOSITORY}/releases"

prefix="/Applications"
archive=""
tag=""
force=0
launch=1

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '%s\n' "$*"
}

usage() {
    sed -n '3,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) prefix="${2:?--prefix needs a directory}"; shift 2 ;;
        --archive) archive="${2:?--archive needs a path}"; shift 2 ;;
        --version) tag="${2:?--version needs a tag}"; shift 2 ;;
        --force) force=1; shift ;;
        --no-open) launch=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# One architecture is published. Failing here is better than downloading 90 MB
# that cannot run: an Intel Mac cannot execute an arm64 bundle at all.
[[ "$(uname -m)" == "arm64" ]] || die "releases are arm64 only; this Mac is $(uname -m)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -n "$archive" ]]; then
    [[ -f "$archive" ]] || die "no such file: $archive"
    cp "$archive" "$work/"
    name="$(basename "$archive")"
    checksums="$(dirname "$archive")/SHA256SUMS"
    [[ -f "$checksums" ]] || die "SHA256SUMS is missing next to $archive"
    cp "$checksums" "$work/"
    note "using local archive $name"
else
    # `%{url_effective}` after following the redirect is the tag URL. Cheaper and
    # steadier than parsing JSON, and it needs no python3 — which a fresh Mac
    # without the command-line tools does not have.
    if [[ -z "$tag" ]]; then
        tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' "${RELEASES}/latest" | sed 's|.*/tag/||')" \
            || die "no release has been published yet (${RELEASES})"
        [[ -n "$tag" ]] || die "could not determine the latest release tag"
    fi
    version="${tag#v}"
    name="OpenSVN-${version}-macos-arm64.zip"

    note "downloading ${tag} …"
    curl -fsSL --retry 3 -o "$work/$name" "${RELEASES}/download/${tag}/${name}" \
        || die "download failed: ${RELEASES}/download/${tag}/${name}"
    curl -fsSL --retry 3 -o "$work/SHA256SUMS" "${RELEASES}/download/${tag}/SHA256SUMS" \
        || die "this release has no SHA256SUMS; refusing to install an unchecked archive"
fi

# The digest has to match exactly. `shasum -c` is not used because it would also
# open every other file the manifest happens to mention.
expected="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$work/SHA256SUMS")"
[[ -n "$expected" ]] || die "$name is not listed in SHA256SUMS"
actual="$(shasum -a 256 "$work/$name" | awk '{ print $1 }')"
[[ "$expected" == "$actual" ]] || die "checksum mismatch for $name (expected $expected, got $actual)"
note "sha256 $actual"

mkdir -p "$work/unpacked"
ditto -xk "$work/$name" "$work/unpacked" || die "cannot unpack $name"
source="$work/unpacked/$APP_NAME"
[[ -d "$source" ]] || die "$name does not contain $APP_NAME"

# Catches a truncated archive and an unpack that lost the signature. An ad-hoc
# signature has no team to compare, which is expected here and not an error.
codesign --verify --deep --strict "$source" 2>/dev/null \
    || die "$APP_NAME does not pass codesign --verify; the archive is damaged"

destination="$prefix/$APP_NAME"
if [[ -e "$destination" ]]; then
    [[ "$force" -eq 1 ]] || die "$destination already exists; pass --force to replace it (or use 检查更新… inside the app)"
    pgrep -x "OpenSVN" >/dev/null 2>&1 && die "OpenSVN is running; quit it first"
    mkdir -p "$HOME/.Trash"
    moved="$HOME/.Trash/OpenSVN-$(date +%Y%m%d-%H%M%S).app"
    # Moved, not deleted: an installer that silently removes an application is
    # one bad argument away from being destructive.
    mv "$destination" "$moved"
    note "previous version moved to $moved"
fi

mkdir -p "$prefix" 2>/dev/null || true
[[ -w "$prefix" ]] || die "$prefix is not writable; rerun with --prefix ~/Applications"
ditto "$source" "$destination"

# Only matters if this script was run against a file something else downloaded:
# curl sets no quarantine flag, so normally there is nothing to strip.
if xattr "$destination" 2>/dev/null | grep -q com.apple.quarantine; then
    xattr -dr com.apple.quarantine "$destination"
    note "cleared an inherited quarantine flag"
fi

note "installed $destination"
if [[ "$launch" -eq 1 ]]; then
    open "$destination"
fi
