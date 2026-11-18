#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: perf-capture.sh --page analytics|qc_report [--robot-name NAME] [--out <dir>] [--remote]

HUB-106: drives a real page with Playwright (the NovAI build only - checks
brand-check.sh first, refuses to run otherwise), waits for it to be
genuinely usable, and saves a HAR, a Performance trace, and a metrics.json
into a dated folder. Then runs perf-report.sh on the HAR plus the matching
slice of NovApi's own log, producing one combined report.html in the same
folder. Run trace-secret-scan.sh on the trace before sharing it anywhere.

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
  --robot-name NAME    default: PERF_ROBOT_NAME from perf-targets.env
  --out DIR             default: a new dated folder under
                       .state/perf-results/
  --remote               target is not this local stack: skips brand-check.sh
                       (it can only read local state) and the local NovApi
                       log slice/pairing (there is none to read). Local runs
                       are unaffected - this flag only changes what happens
                       when you pass it. Refuses up front, before contacting
                       anything, if perf-targets.env has no robot name or URL
                       - there is no local fallback in remote mode.

Robot name and NOVAPP_URL/NOVAPI_URL come from perf-targets.env (one file,
git-ignored, auto-created from the committed perf-targets.env.example with
local defaults on first run - edit your own copy to target dev; never commit
it). Credentials stay only in the 0600 PERF_SECRET_FILE, never in that file
either.

Needs ./perf-setup.sh already run (installs Playwright) and the stack up
(opensearch/novapi/novapp) as the NovAI build - or, with --remote, just the
target reachable at perf-targets.env's URLs and a valid PERF_SECRET_FILE for it.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ensure_perf_config

PAGE=""
ROBOT_NAME=""
OUT_DIR=""
REMOTE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --page) PAGE="$2"; shift 2 ;;
    --robot-name) ROBOT_NAME="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --remote) REMOTE=1; shift ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done
if [ -z "$PAGE" ]; then
  error "--page analytics|qc_report is required"
  exit 1
fi
[ -n "$ROBOT_NAME" ] || ROBOT_NAME="$(perf_config_get PERF_ROBOT_NAME)"
[ -z "${NOVAPP_URL:-}" ] && NOVAPP_URL="$(perf_config_get NOVAPP_URL)"
[ -z "${NOVAPI_URL:-}" ] && NOVAPI_URL="$(perf_config_get NOVAPI_URL)"
export NOVAPP_URL NOVAPI_URL

if [ "$REMOTE" -eq 1 ]; then
  [ -n "$ROBOT_NAME" ] || { error "remote mode: perf-targets.env has no PERF_ROBOT_NAME set - refusing, no local fallback"; exit 1; }
  [ -n "$NOVAPP_URL" ] || { error "remote mode: perf-targets.env has no NOVAPP_URL set - refusing, no local fallback"; exit 1; }
  [ -n "$NOVAPI_URL" ] || { error "remote mode: perf-targets.env has no NOVAPI_URL set - refusing, no local fallback"; exit 1; }
elif [ -z "$ROBOT_NAME" ]; then
  error "no robot name - set PERF_ROBOT_NAME in perf-targets.env or pass --robot-name"
  exit 1
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$STATE_DIR/perf-results/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT_DIR"

if [ "$REMOTE" -eq 1 ]; then
  log "remote mode: skipping brand-check.sh - it only reads this stack's local state, not the target's"
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

log "capturing: $PAGE for $ROBOT_NAME -> $OUT_DIR"
NODE_PATH="$PERF_DIR/node_modules" node "$SCRIPT_DIR/perf-capture.js" \
  --page="$PAGE" --robot-name="$ROBOT_NAME" --out="$OUT_DIR"

REPORT_ARGS=(--har "$OUT_DIR/${PAGE}.har" --out "$OUT_DIR")
if [ "$REMOTE" -eq 1 ]; then
  log "remote mode: no local NovApi log to pair with this HAR - pass one with perf-report.sh --novapi-log yourself if you have it"
elif [ -f "$NOVAPI_LOG" ]; then
  tail -n "+$((log_start_line + 1))" "$NOVAPI_LOG" > "$OUT_DIR/${PAGE}-novapi.log.slice"
  log "created: $OUT_DIR/${PAGE}-novapi.log.slice"
  REPORT_ARGS+=(--novapi-log "$OUT_DIR/${PAGE}-novapi.log.slice")
fi

"$SCRIPT_DIR/perf-report.sh" "${REPORT_ARGS[@]}"

log "report: $OUT_DIR/report.html"
