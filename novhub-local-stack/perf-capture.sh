#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: perf-capture.sh --page analytics|qc_report [--robot-name NAME] [--out <dir>] [--target NAME]

HUB-106: drives a real page with Playwright, waits for it to be genuinely
usable, and saves a HAR, a Performance trace, and a metrics.json into a
dated folder. Then runs perf-report.sh on the HAR plus the matching slice
of NovApi's own log (local target only), producing one combined
report.html in the same folder. Run trace-secret-scan.sh on the trace
before sharing it anywhere.

metrics.json: request counts per endpoint, total scripting time, longest
task. "Usable" on Analytics is DOM-based (list_usable_ms/detail_usable_ms -
QC-status badges filled + row count stable, the second measured from the
row click); QC Report has no QC-status badge column, so it keeps
time_to_usable_ms (network-idle: last matching request starts + ~1200ms of
no further matching requests) as its only signal. time_to_usable_ms is kept
on every page as a secondary, labelled proxy even where the DOM metrics
exist - it tracks request ordering, not work volume.

  --page analytics    WeldSessions/WeldInformation (clicks a row, so both
                       the list-load and detail-view per-run calls fire)
  --page qc_report     WeldQualityList (already batched, no per-run calls -
                       use as the control/comparison page)
  --robot-name NAME    default: PERF_ROBOT_NAME from this target's config
  --out DIR             default: a new dated folder under
                       .state/perf-results/
  --target NAME          which config/secret file to use - default "local"
                       (this stack, brand-checked, NovApi log paired).
                       Any other name (e.g. test, dev) means: skip
                       brand-check.sh and the local NovApi-log pairing -
                       both only know how to read this stack's own local
                       state - and refuse up front, before contacting
                       anything, if that target's config has no robot
                       name, URL, or date range, or its secret file is
                       missing or not exactly 0600. There is no local
                       fallback for a named target.

On the analytics page, PERF_RANGE_START/PERF_RANGE_END (YYYY-MM-DD) are set
through the date-range picker UI itself after the page settles on its
default range - Analytics has no URL param for this. Both required
together for any non-local --target (refuses up front if only one is set,
if either isn't YYYY-MM-DD, or if the end is before the start); optional
locally. metrics.json reports which range was actually used.

Robot name and NOVAPP_URL/NOVAPI_URL come from perf-targets.env for
--target local (one file, git-ignored, auto-created from the committed
perf-targets.env.example with local defaults on first run), or from
perf-targets.<target>.env for any other --target, which must already
exist - create it yourself (same KEY=value format) first. Nothing about a
named target is ever committed. Credentials stay only in a 0600 secret
file, never in either config file - local target:
.state/secrets/perf-test-user.secret; any other target:
.state/secrets/perf-test-user-<target>.secret (both overridable with
PERF_SECRET_FILE).

Needs ./perf-setup.sh already run (installs Playwright) and, for --target
local, the stack up (opensearch/novapi/novapp) as the NovAI build. For any
other target, just that target reachable and its secret file in place.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PAGE=""
ROBOT_NAME=""
OUT_DIR=""
TARGET="local"
while [ $# -gt 0 ]; do
  case "$1" in
    --page) PAGE="$2"; shift 2 ;;
    --robot-name) ROBOT_NAME="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done
if [ -z "$PAGE" ]; then
  error "--page analytics|qc_report is required"
  exit 1
fi

ensure_perf_config "$TARGET"
if [ "$TARGET" = "local" ]; then REMOTE=0; else REMOTE=1; fi

[ -n "$ROBOT_NAME" ] || ROBOT_NAME="$(perf_config_get PERF_ROBOT_NAME)"
[ -z "${NOVAPP_URL:-}" ] && NOVAPP_URL="$(perf_config_get NOVAPP_URL)"
[ -z "${NOVAPI_URL:-}" ] && NOVAPI_URL="$(perf_config_get NOVAPI_URL)"
export NOVAPP_URL NOVAPI_URL

[ -n "${PERF_SECRET_FILE:-}" ] || PERF_SECRET_FILE="$(perf_secret_file_for_target "$TARGET")"
export PERF_SECRET_FILE

[ -z "${PERF_RANGE_START:-}" ] && PERF_RANGE_START="$(perf_config_get PERF_RANGE_START)"
[ -z "${PERF_RANGE_END:-}" ] && PERF_RANGE_END="$(perf_config_get PERF_RANGE_END)"
export PERF_RANGE_START PERF_RANGE_END

if [ "$REMOTE" -eq 1 ]; then
  [ -n "$ROBOT_NAME" ] || { error "target '$TARGET': $PERF_CONFIG_FILE has no PERF_ROBOT_NAME set - refusing, no local fallback"; exit 1; }
  [ -n "$NOVAPP_URL" ] || { error "target '$TARGET': $PERF_CONFIG_FILE has no NOVAPP_URL set - refusing, no local fallback"; exit 1; }
  [ -n "$NOVAPI_URL" ] || { error "target '$TARGET': $PERF_CONFIG_FILE has no NOVAPI_URL set - refusing, no local fallback"; exit 1; }
  [ -n "$PERF_RANGE_START" ] || { error "target '$TARGET': $PERF_CONFIG_FILE has no PERF_RANGE_START set - refusing, no local fallback"; exit 1; }
  [ -n "$PERF_RANGE_END" ] || { error "target '$TARGET': $PERF_CONFIG_FILE has no PERF_RANGE_END set - refusing, no local fallback"; exit 1; }
elif [ -z "$ROBOT_NAME" ]; then
  error "no robot name - set PERF_ROBOT_NAME in $PERF_CONFIG_FILE or pass --robot-name"
  exit 1
fi

if [ -n "$PERF_RANGE_START" ] || [ -n "$PERF_RANGE_END" ]; then
  if [ -z "$PERF_RANGE_START" ] || [ -z "$PERF_RANGE_END" ]; then
    error "PERF_RANGE_START and PERF_RANGE_END must both be set or both be empty - refusing"
    exit 1
  fi
  for d in "$PERF_RANGE_START" "$PERF_RANGE_END"; do
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { error "PERF_RANGE_START/PERF_RANGE_END must be YYYY-MM-DD - got '$d'"; exit 1; }
  done
  if [[ "$PERF_RANGE_END" < "$PERF_RANGE_START" ]]; then
    error "PERF_RANGE_END ($PERF_RANGE_END) is before PERF_RANGE_START ($PERF_RANGE_START) - refusing"
    exit 1
  fi
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$STATE_DIR/perf-results/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT_DIR"

if [ "$REMOTE" -eq 1 ]; then
  log "target '$TARGET': skipping brand-check.sh - it only reads this stack's local state, not the target's"
else
  "$SCRIPT_DIR/brand-check.sh"
fi

PERF_DIR="$SCRIPT_DIR/.cache/perf-tools"
if [ ! -d "$PERF_DIR/node_modules/playwright" ]; then
  error "Playwright not installed - run ./perf-setup.sh first"
  exit 1
fi

NOVAPI_LOG="$STATE_DIR/novapi.log"
log_start_line=0
if [ "$REMOTE" -eq 0 ] && [ -f "$NOVAPI_LOG" ]; then
  log_start_line="$(wc -l < "$NOVAPI_LOG")"
fi

log "capturing: $PAGE for $ROBOT_NAME (target: $TARGET) -> $OUT_DIR"
NODE_PATH="$PERF_DIR/node_modules" node "$SCRIPT_DIR/perf-capture.js" \
  --page="$PAGE" --robot-name="$ROBOT_NAME" --out="$OUT_DIR"

REPORT_ARGS=(--har "$OUT_DIR/${PAGE}.har" --out "$OUT_DIR")
if [ "$REMOTE" -eq 1 ]; then
  log "target '$TARGET': no local NovApi log to pair with this HAR - pass one with perf-report.sh --novapi-log yourself if you have it"
elif [ -f "$NOVAPI_LOG" ]; then
  tail -n "+$((log_start_line + 1))" "$NOVAPI_LOG" > "$OUT_DIR/${PAGE}-novapi.log.slice"
  log "created: $OUT_DIR/${PAGE}-novapi.log.slice"
  REPORT_ARGS+=(--novapi-log "$OUT_DIR/${PAGE}-novapi.log.slice")
fi

"$SCRIPT_DIR/perf-report.sh" "${REPORT_ARGS[@]}"

log "report: $OUT_DIR/report.html"
