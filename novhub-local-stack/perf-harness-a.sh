#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: perf-harness-a.sh

HUB-106 endpoint baseline: times the five endpoints relevant to the Analytics
page, against the real ingested robots (perf-ingester-load.sh's output):
  a) GET  weld_run                - the page's run list
  b) GET  weld_test_reports x N   - one per run, fired PERF_PARALLEL_CONCURRENCY
                                     at a time (today's real per-run pattern)
  c) POST weld_test_reports/batch - PERF_BATCH_SIZE runs per call
  d) POST weld_stats/batch        - PERF_BATCH_SIZE run_ids per call
  e) GET  weld_stats               - one page-wide call
Read-only against NovApi - no code changes. Logs in as the seeded synthetic
test user automatically. Every run's full result, plus the slice of NovApi's
own per-request log covering it, is saved under .state/perf-results/<UTC
timestamp>/ so results can be kept and compared before/after.

Env overrides: PERF_ROBOT_IDS (default 910001,910002), PERF_PER_PAGE (2000),
PERF_TRIALS (3), PERF_PARALLEL_CONCURRENCY (6), PERF_BATCH_SIZE (500),
PERF_STATS_RANGE_DAYS (60, for the page-wide call's date range).

Needs run-novhub.sh up's OpenSearch container, NovApi's own docker compose
stack running, and perf-ingester-seed.sh seed + seed-reports already run.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

VENV_DIR="$NOVHUB_ROOT/.venv"
if [ -d "$VENV_DIR" ]; then
  log "already exists: $VENV_DIR"
else
  python3 -m venv "$VENV_DIR"
  log "created: $VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -q -r "$NOVHUB_ROOT/requirements.txt"

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/perf-harness-a.py"
