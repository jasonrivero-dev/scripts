#!/usr/bin/env bash

LOG_DIR="${HOME}/dev/celeste-files/NovEye/logs"
POLL_SECONDS=2

usage() {
    echo "Usage: $(basename "$0") [pattern]"
    echo
    echo "Tails the newest log in ${LOG_DIR}, following celeste across restarts:"
    echo "if a newer log file appears while this is running, it switches to it"
    echo "automatically instead of staying stuck on the old one."
    echo "With a pattern, filters live via grep -i (case-insensitive, matches as they arrive)."
    echo
    echo "Examples:"
    echo "  $(basename "$0")            # whole live log, unfiltered"
    echo "  $(basename "$0") licensing  # only lines matching 'licensing' (case-insensitive)"
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

pattern="$1"

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
    echo "======================================================================"
    if [[ -z "$pattern" ]]; then
        echo "Tailing: ${latest}"
    else
        echo "Tailing: ${latest} | pattern: ${pattern}"
    fi
    echo "======================================================================"

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
