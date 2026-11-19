#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: perf-sweep.sh

HUB-106: sweeps page/batch size on the SAME frozen dataset (no re-ingest) to
show how response time grows with request size - standing in for "more
data" since local hardware can't hold production-scale (millions-of-runs)
volume. Read-only against NovApi.

Env overrides: PERF_ROBOT_ID (default 910001), PERF_SWEEP_PAGE_SIZES
(default 100,500,1000,2000), PERF_SWEEP_BATCH_SIZES (default 100,250,500 -
weld_test_reports/batch caps at 500 entries per call), PERF_SWEEP_TRIALS
(default 3).
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

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/perf-sweep.py"
