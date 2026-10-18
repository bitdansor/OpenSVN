#!/usr/bin/env bash
# Shared helpers for the S5-5 fault-injection scenarios. Source it; never run it.
#
# The runner (`tests/scenarios/run.sh`) exports SCENARIO_ROOT, SCENARIO_DIR,
# SCENARIO_ID and SCENARIO_WORK, and runs arrange.sh, act.sh and assert.sh as
# three separate processes. Anything act.sh learns therefore has to be written
# to $SCENARIO_WORK/state and read back by assert.sh.
#
# Conventions used by every scenario:
#   exit 0   the stage did what it was supposed to do
#   exit 77  the scenario cannot run here (missing tool, missing build) — SKIP
#   other    the stage itself broke; the runner reports FAIL and prints the log
#
# svn failing on purpose is *data*, not a broken stage: `run_capture` records its
# exit code and output, and assert.sh decides whether that is the expected result.

set -uo pipefail

: "${SCENARIO_ROOT:?source this from a scenario script run by tests/scenarios/run.sh}"
: "${SCENARIO_WORK:?source this from a scenario script run by tests/scenarios/run.sh}"

STATE="$SCENARIO_WORK/state"
PIDS="$SCENARIO_WORK/pids"
SUPPORT="$SCENARIO_ROOT/tests/scenarios/support"

SVN="${SVN:-svn}"
SVNADMIN="${SVNADMIN:-svnadmin}"
SVNSERVE="${SVNSERVE:-svnserve}"
SVNLOOK="${SVNLOOK:-svnlook}"
PYTHON="${PYTHON:-python3}"

REPO="$SCENARIO_WORK/repo"
SEED="$SCENARIO_WORK/seed"
# Derived here rather than inside make_repo: arrange, act and assert are separate
# processes, so anything act.sh or assert.sh needs must not be created in arrange.
REPO_URL="file://$REPO"

mkdir -p "$STATE" "$PIDS"

# ---------------------------------------------------------------- environment

require_tools() {
    local missing=()
    local tool
    for tool in "$SVN" "$SVNADMIN" "$SVNSERVE" "$SVNLOOK" "$PYTHON"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} )); then
        echo "SKIP: missing required tool(s): ${missing[*]}" >&2
        exit 77
    fi
}

# The probe is built from the same package as the app; without it a scenario
# cannot assert what the app would have shown.
probe_bin() {
    local bin="$SCENARIO_ROOT/apps/macos/.build/debug/opensvn-probe"
    if [[ ! -x "$bin" ]]; then
        bin="$SCENARIO_ROOT/apps/macos/.build/release/opensvn-probe"
    fi
    if [[ ! -x "$bin" ]]; then
        echo "SKIP: opensvn-probe not built (run: swift build --product opensvn-probe)" >&2
        exit 77
    fi
    printf '%s\n' "$bin"
}

# ------------------------------------------------------------------- fixtures

# A repository plus one trunk file, small enough to be instant.
make_repo() {
    rm -rf "$REPO" "$SEED"
    mkdir -p "$SEED/trunk"
    printf 'initial content\n' > "$SEED/trunk/tracked.txt"
    "$SVNADMIN" create "$REPO" >/dev/null
    "$SVN" import "$SEED" "$REPO_URL" -m "初始导入" --no-auth-cache >/dev/null
}

repo_url() { printf '%s\n' "$REPO_URL"; }

repo_head() { "$SVNLOOK" youngest "$REPO"; }

checkout() { # <url> <dest>
    "$SVN" checkout "$1" "$2" --no-auth-cache --non-interactive >/dev/null
}

# --------------------------------------------------------------- run + record

# run_capture <name> <command...>
# Records exit code, stdout, stderr and the command line under $STATE.
# Always returns 0: the failure being studied is expected, not a broken stage.
run_capture() {
    local name=$1
    shift
    printf '%s\n' "$*" > "$STATE/$name.cmd"
    "$@" > "$STATE/$name.out" 2> "$STATE/$name.err"
    echo "$?" > "$STATE/$name.exit"
    return 0
}

capture_exit() { cat "$STATE/$1.exit"; }
capture_out() { cat "$STATE/$1.out"; }
capture_err() { cat "$STATE/$1.err"; }

# classify <name>
# Feeds a captured failure through the app's own mapper and caches the result.
classify() {
    local name=$1
    local bin
    bin=$(probe_bin)
    "$bin" map-error \
        --exit "$(capture_exit "$name")" \
        --stdout "$STATE/$name.out" \
        < "$STATE/$name.err" > "$STATE/$name.probe" || true
    cat "$STATE/$name.probe"
}

probe_field() { # <name> <key>
    sed -n "s/^$2=//p" "$STATE/$1.probe"
}

# ---------------------------------------------------------------- networking

free_port() {
    "$PYTHON" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_port() { # <host> <port> [seconds]
    local host=$1 port=$2 seconds=${3:-10} i=0
    while (( i < seconds * 10 )); do
        if "$PYTHON" - "$host" "$port" <<'PY'
import socket, sys
sock = socket.socket()
sock.settimeout(0.2)
raise SystemExit(0 if sock.connect_ex((sys.argv[1], int(sys.argv[2]))) == 0 else 1)
PY
        then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# start_svnserve <repo-root-dir> <port>
# `-d --foreground` is the combination that keeps the daemon in the foreground so
# the harness owns the pid. `--foreground` alone is not a mode and svnserve
# refuses it with "You must specify exactly one of -d, -i, -t or -X".
start_svnserve() {
    local root=$1 port=$2
    "$SVNSERVE" -d --foreground -r "$root" --listen-host 127.0.0.1 --listen-port "$port" \
        > "$STATE/svnserve-$port.log" 2>&1 &
    echo $! > "$PIDS/svnserve-$port.pid"
    wait_port 127.0.0.1 "$port" 10 || {
        cat "$STATE/svnserve-$port.log" >&2
        echo "svnserve did not start on port $port" >&2
        exit 1
    }
}

# start_proxy <listen-port> <target-port> [cut-after-bytes]
start_proxy() {
    local listen=$1 target=$2 cut=${3:-0}
    "$PYTHON" "$SUPPORT/tcp_proxy.py" \
        --listen-port "$listen" --target-port "$target" --cut-after "$cut" \
        > "$STATE/proxy-$listen.log" 2>&1 &
    echo $! > "$PIDS/proxy-$listen.pid"
    wait_port 127.0.0.1 "$listen" 10 || {
        cat "$STATE/proxy-$listen.log" >&2
        echo "proxy did not start on port $listen" >&2
        exit 1
    }
}

# stop_pid <pidfile> — terminates a recorded background process and waits for it.
stop_pid() {
    local pidfile=$1 pid i
    [[ -e "$pidfile" ]] || return 0
    pid=$(cat "$pidfile" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        i=0
        while (( i < 30 )) && kill -0 "$pid" 2>/dev/null; do
            sleep 0.1
            i=$((i + 1))
        done
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$pidfile"
}

# ---------------------------------------------------------------- assertions

fail() {
    echo "assertion failed: $*" >&2
    exit 1
}

# The operation under test must fail. Silent success is the failure mode most of
# these scenarios exist to catch.
assert_failed() { # <capture>
    local code
    code=$(capture_exit "$1")
    [[ "$code" != "0" ]] || fail "$1: expected a non-zero exit, got 0 (the fault did not happen)"
}

assert_succeeded() { # <capture>
    assert_eq "$(capture_exit "$1")" "0" "$1 exit code"
}

assert_eq() { # <actual> <expected> <label>
    [[ "$1" == "$2" ]] || fail "${3:-value}: expected '$2', got '$1'"
}

assert_contains() { # <haystack> <needle> <label>
    [[ "$1" == *"$2"* ]] || fail "${3:-text}: expected to contain '$2'"
}

assert_not_contains() { # <haystack> <needle> <label>
    [[ "$1" != *"$2"* ]] || fail "${3:-text}: must not contain '$2'"
}

assert_file_exists() {
    [[ -e "$1" ]] || fail "${2:-path}: expected '$1' to exist"
}

assert_file_absent() {
    [[ ! -e "$1" ]] || fail "${2:-path}: expected '$1' to be absent"
}

assert_probe() { # <capture> <key> <expected>
    local actual
    actual=$(probe_field "$1" "$2")
    assert_eq "$actual" "$3" "probe $1.$2"
}

# Asserts the captured failure classifies as <SVN-xxxx>, and that the remediation
# does not push the user towards a dead end (the whole point of several cases).
assert_classified_as() { # <capture> <SVN-id>
    classify "$1" >/dev/null
    assert_probe "$1" code "$2"
}

# svn status --xml must still parse: a half-written working copy would break the
# app's only source of truth about what changed.
assert_status_parseable() { # <working-copy>
    local wc=$1
    "$SVN" status --xml --non-interactive --no-auth-cache "$wc" \
        > "$STATE/status-$(basename "$wc").xml" 2> "$STATE/status-$(basename "$wc").err"
    assert_eq "$?" "0" "svn status --xml exit code"
    "$PYTHON" - "$STATE/status-$(basename "$wc").xml" <<'PY' || fail "svn status --xml emitted invalid XML"
import sys, xml.etree.ElementTree as ET
ET.parse(sys.argv[1])
PY
}

# xml_items <file> <item> -> one path per line
xml_items() {
    "$PYTHON" - "$1" "$2" <<'PY'
import sys, xml.etree.ElementTree as ET
for entry in ET.parse(sys.argv[1]).getroot().iter("entry"):
    status = entry.find("wc-status")
    if status is not None and status.get("item") == sys.argv[2]:
        print(entry.get("path"))
PY
}
