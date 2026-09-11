#!/usr/bin/env bash

DEV_LOG_DIR="${HOME}/dev/celeste-files/NovEye/logs"
PROD_LOG_DIR="/var/log/novarc/celeste"
LOG_DIR="$DEV_LOG_DIR"
POLL_SECONDS=2

usage() {
    echo "Usage: $(basename "$0") [-p|--production] [pattern]"
    echo
    echo "Tails the newest log, following celeste across restarts: if a newer log"
    echo "file appears while this is running, it switches to it automatically"
    echo "instead of staying stuck on the old one."
    echo
    echo "  -p, --production   Use ${PROD_LOG_DIR} instead of the dev default"
    echo "                     ${DEV_LOG_DIR}"
    echo
    echo "With a pattern, filters live via grep -i (case-insensitive, matches as they arrive)."
    echo
    echo "Examples:"
    echo "  $(basename "$0")               # whole live dev log, unfiltered"
    echo "  $(basename "$0") licensing     # only lines matching 'licensing' (case-insensitive)"
    echo "  $(basename "$0") -p licensing  # same, but against the production log"
}

pattern=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -p|--production) LOG_DIR="$PROD_LOG_DIR"; shift ;;
        *) pattern="$1"; shift ;;
    esac
done

find_latest() {
    ls -t "${LOG_DIR}"/NovEye.g3log.*.log 2>/dev/null | head -n 1
}

cleanup() {
    [[ -n "${watcher_pid:-}" ]] && kill "$watcher_pid" 2>/dev/null
}
trap cleanup EXIT

while true; do
    latest=$(find_latest)
    if [[ -z "$latest" ]]; then
        echo "No log files found in ${LOG_DIR}" >&2
        exit 1
    fi

    bn="$(basename "$latest")"

    echo
    echo "============================================================================================================================================"
    if [[ -z "$pattern" ]]; then
        echo "Tailing: ${latest}"
    else
        echo "Tailing: ${latest} | pattern: ${pattern}"
    fi
    echo "============================================================================================================================================"

    # Watches for a newer log appearing (celeste restarted) and kills this
    # iteration's tail so the outer loop can pick it up - tail -f alone has
    # no way to notice a brand new filename on its own.
    (
        while true; do
            sleep "$POLL_SECONDS"
            [[ "$(find_latest)" != "$latest" ]] && { pkill -f "tail -n \+1 -f $latest" 2>/dev/null; break; }
        done
    ) &
    watcher_pid=$!

    # -n +1: start from the beginning of the file, not just the last 10 lines.
    # Without this, a pattern that only matched during celeste's own startup
    # (seconds before this script attaches) would never be seen - tail -f's
    # default window would already be past it by the time we catch up.
    if [[ -z "$pattern" ]]; then
        tail -n +1 -f "$latest" | sed -u "s|^|[${bn}] |"
    else
        # -- guards against a pattern that itself starts with '-' being misread as a grep option.
        tail -n +1 -f "$latest" | grep -i --line-buffered -- "$pattern" | sed -u "s|^|[${bn}] |"
    fi

    kill "$watcher_pid" 2>/dev/null
done
