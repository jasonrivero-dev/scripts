#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: perf-after.sh [--out <dir>] [--robot-name PERF-ING-910001] [--har <path>] [--trace <path>]

HUB-106: repeats the exact BEFORE measurement set on the same frozen dataset, one command -
NovAI brand check, frozen-dataset count check, endpoint baseline (perf-harness-a), size sweep
(perf-sweep), Playwright capture of Analytics (with the row click) and QC Report. If the owner
has already manually re-exported a HAR and/or a Performance trace for this AFTER run, pass them
with --har/--trace to fold them in too (a --trace is scanned with trace-secret-scan.sh first -
refuses to fold in a trace that scan flags).

Writes everything into one after-<timestamp> folder (default: alongside before-20261117T183701Z
under ~/dev/presentations/novhub-local-stack/hub106-perf-results/). Each measurement keeps its
own report.html/data.json inside that folder under a distinct name (baseline-*, analytics-*,
qc_report-*, manual-har-*, manual-trace-*) - they cover different time windows, so this does not
force them into one combined report; use perf-report.sh --compare to build the before/after comparison.

  --out <dir>            default: hub106-perf-results/after-<UTC timestamp>
  --robot-name NAME      default PERF-ING-910001 (must match the BEFORE run's robot for a
                          meaningful comparison)
  --har <path>            owner's manually re-exported HAR for this AFTER run
  --trace <path>          owner's manually re-exported Performance trace for this AFTER run

Needs the stack up (opensearch/novapi/novapp), perf-ingester-seed.sh seed + seed-reports already
run - same prerequisites as the BEFORE run.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/steps/opensearch.sh"

OUT_DIR=""
ROBOT_NAME="PERF-ING-910001"
HAR_PATH=""
TRACE_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --robot-name) ROBOT_NAME="$2"; shift 2 ;;
    --har) HAR_PATH="$2"; shift 2 ;;
    --trace) TRACE_PATH="$2"; shift 2 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done
[ -n "$OUT_DIR" ] || OUT_DIR="$HOME/dev/presentations/novhub-local-stack/hub106-perf-results/after-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR"
log "after-run folder: $OUT_DIR"

log "brand check..."
"$SCRIPT_DIR/brand-check.sh"

ES_INDEX_INGESTER="${ES_INDEX:-novhub-local-ingester}"
log "confirming the frozen dataset is unchanged ($ES_INDEX_INGESTER, robots 910001+910002)..."
count="$(curl -s "http://127.0.0.1:${OPENSEARCH_PORT}/${ES_INDEX_INGESTER}/_count" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"terms":{"robot.robot_id":[910001,910002]}}}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','?'))")"
if [ "$count" != "6002000" ]; then
  error "FAILED: frozen dataset changed ($ES_INDEX_INGESTER count=$count, expected 6002000) - stop and reconcile before measuring, this AFTER run would not be comparable to BEFORE"
  exit 1
fi
log "ok: frozen dataset unchanged (6002000 docs)"

log "endpoint baseline (perf-harness-a)..."
HARNESS_TMP="$OUT_DIR/.harness-tmp"
rm -rf "$HARNESS_TMP"
PERF_RESULTS_DIR="$HARNESS_TMP" "$SCRIPT_DIR/perf-harness-a.sh"
HARNESS_RUN_DIR="$(find "$HARNESS_TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
mv "$HARNESS_RUN_DIR"/results.json "$OUT_DIR/results.json"
mv "$HARNESS_RUN_DIR"/novapi.log.slice "$OUT_DIR/novapi.log.slice"
rm -rf "$HARNESS_TMP"
log "created: $OUT_DIR/results.json, $OUT_DIR/novapi.log.slice"

"$SCRIPT_DIR/perf-report.sh" --novapi-log "$OUT_DIR/novapi.log.slice" --out "$OUT_DIR" >/dev/null
mv "$OUT_DIR/report.html" "$OUT_DIR/baseline-report.html"
mv "$OUT_DIR/data.json" "$OUT_DIR/baseline-data.json"
log "created: $OUT_DIR/baseline-report.html"

log "size sweep (perf-sweep)..."
"$SCRIPT_DIR/perf-sweep.sh" > "$OUT_DIR/size-sweep.json"
log "created: $OUT_DIR/size-sweep.json"

log "Playwright capture: analytics (with row click)..."
"$SCRIPT_DIR/perf-capture.sh" --page analytics --robot-name "$ROBOT_NAME" --out "$OUT_DIR" >/dev/null
mv "$OUT_DIR/report.html" "$OUT_DIR/analytics-report.html"
mv "$OUT_DIR/data.json" "$OUT_DIR/analytics-data.json"
log "created: $OUT_DIR/analytics.har, $OUT_DIR/analytics-metrics.json, $OUT_DIR/analytics-report.html"

log "Playwright capture: qc_report..."
"$SCRIPT_DIR/perf-capture.sh" --page qc_report --robot-name "$ROBOT_NAME" --out "$OUT_DIR" >/dev/null
mv "$OUT_DIR/report.html" "$OUT_DIR/qc_report-report.html"
mv "$OUT_DIR/data.json" "$OUT_DIR/qc_report-data.json"
log "created: $OUT_DIR/qc_report.har, $OUT_DIR/qc_report-metrics.json, $OUT_DIR/qc_report-report.html"

if [ -n "$TRACE_PATH" ]; then
  log "owner-provided trace: scanning for secrets first..."
  "$SCRIPT_DIR/trace-secret-scan.sh" "$TRACE_PATH" || {
    error "FAILED: trace-secret-scan found something in $TRACE_PATH - not folding it in until resolved"
    exit 1
  }
  "$SCRIPT_DIR/perf-report.sh" --trace "$TRACE_PATH" --capture-metrics "$OUT_DIR/analytics-metrics.json" --out "$OUT_DIR" >/dev/null
  mv "$OUT_DIR/report.html" "$OUT_DIR/manual-trace-report.html"
  mv "$OUT_DIR/data.json" "$OUT_DIR/manual-trace-data.json"
  log "created: $OUT_DIR/manual-trace-report.html"
else
  log "no --trace given - owner has not manually re-exported a Performance trace for AFTER yet"
fi

if [ -n "$HAR_PATH" ]; then
  "$SCRIPT_DIR/perf-report.sh" --har "$HAR_PATH" --out "$OUT_DIR" >/dev/null
  mv "$OUT_DIR/report.html" "$OUT_DIR/manual-har-report.html"
  mv "$OUT_DIR/data.json" "$OUT_DIR/manual-har-data.json"
  log "created: $OUT_DIR/manual-har-report.html"
else
  log "no --har given - owner has not manually re-exported a HAR for AFTER yet"
fi

log "ok: after-run complete -> $OUT_DIR"
