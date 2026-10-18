#!/usr/bin/env bash
# Runs the S5-5 fault-injection scenarios.
#
#   tests/scenarios/run.sh                 # every scenario under failure/
#   tests/scenarios/run.sh F8 F11          # only the ones whose name starts with F8 / F11
#   STAGE_TIMEOUT=60 tests/scenarios/run.sh
#
# Each scenario is three stages — arrange, act, assert — run as separate
# processes, so a mistake in one cannot leak state into the next except through
# files. A stage exit of 77 means "cannot run here" and is reported as SKIP, not
# as a pass: a silent skip is how a broken harness stays green for a year.
#
# Deliberately bash-3.2 compatible: that is what /bin/bash is on macOS, and this
# script must run on a stock machine without homebrew bash.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILURE_DIR="$ROOT/tests/scenarios/failure"
WORK_ROOT="$ROOT/tests/.work/scenarios"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-90}"

export SCENARIO_ROOT="$ROOT"

CURRENT_WORK=""

cleanup_current() {
    [[ -n "$CURRENT_WORK" ]] || return 0
    local pidfile pid i
    for pidfile in "$CURRENT_WORK"/pids/*.pid; do
        [[ -e "$pidfile" ]] || continue
        pid=$(cat "$pidfile" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            i=0
            while (( i < 20 )) && kill -0 "$pid" 2>/dev/null; do
                sleep 0.1
                i=$((i + 1))
            done
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$pidfile"
    done
    # F11 makes directories read-only on purpose; without this the runner cannot
    # delete its own scratch tree on the next pass.
    chmod -R u+w "$CURRENT_WORK" 2>/dev/null
}

trap cleanup_current EXIT INT TERM

# run_stage <script> <log-path>
# One stage with a wall-clock ceiling: a hung stage must fail loudly instead of
# blocking CI forever.
run_stage() {
    local script=$1 log=$2 pid i
    "$script" > "$log" 2>&1 &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( i >= STAGE_TIMEOUT * 5 )); then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            echo "timeout after ${STAGE_TIMEOUT}s" >> "$log"
            return 124
        fi
        sleep 0.2
        i=$((i + 1))
    done
    wait "$pid"
}

# 0 = pass, 1 = fail, 2 = skip
run_scenario() {
    local id=$1
    local dir="$FAILURE_DIR/$id"
    export SCENARIO_ID="$id"
    export SCENARIO_DIR="$dir"
    export SCENARIO_WORK="$WORK_ROOT/$id"
    CURRENT_WORK="$SCENARIO_WORK"

    chmod -R u+w "$SCENARIO_WORK" 2>/dev/null
    rm -rf "$SCENARIO_WORK"
    mkdir -p "$SCENARIO_WORK/state" "$SCENARIO_WORK/pids"

    local stage script code
    for stage in arrange act assert; do
        script="$dir/$stage.sh"
        if [[ ! -x "$script" ]]; then
            echo "  FAIL  $id — $stage.sh missing or not executable"
            return 1
        fi
        run_stage "$script" "$SCENARIO_WORK/$stage.log"
        code=$?
        if (( code == 77 )); then
            echo "  SKIP  $id — $(tail -n 1 "$SCENARIO_WORK/$stage.log" 2>/dev/null)"
            return 2
        fi
        if (( code != 0 )); then
            printf '  FAIL  %s — %s.sh exited %d\n' "$id" "$stage" "$code"
            sed 's/^/          /' "$SCENARIO_WORK/$stage.log" | tail -n 12
            return 1
        fi
    done

    echo "  PASS  $id"
    return 0
}

main() {
    if [[ ! -d "$FAILURE_DIR" ]]; then
        echo "no scenarios found in $FAILURE_DIR" >&2
        exit 1
    fi

    local selected="$*"
    local ids="" dir name pick matched
    for dir in "$FAILURE_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        if [[ -z "$selected" ]]; then
            ids="$ids $name"
            continue
        fi
        matched=0
        for pick in $selected; do
            case "$name" in
                "$pick"*) matched=1 ;;
            esac
        done
        [[ "$matched" == 1 ]] && ids="$ids $name"
    done

    if [[ -z "${ids// /}" ]]; then
        echo "no matching scenarios" >&2
        exit 1
    fi

    # Alphabetical order puts F10 before F8; sort on the catalogue number so the
    # output reads in the order of the catalog.
    ids=$(printf '%s\n' $ids | sort -t F -k2,2n)

    mkdir -p "$WORK_ROOT"
    printf '== fault-injection scenarios (svn %s)\n' "$(svn --version --quiet 2>/dev/null || echo 'not found')"

    local passed=0 failed=0 skipped=0 id failing="" code
    for id in $ids; do
        run_scenario "$id"
        code=$?
        case "$code" in
            0) passed=$((passed + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)); failing="$failing $id" ;;
        esac
    done

    cleanup_current
    CURRENT_WORK=""

    echo
    printf '== %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
    if (( failed > 0 )); then
        printf '   failing:%s\n' "$failing"
        exit 1
    fi
}

main "$@"
