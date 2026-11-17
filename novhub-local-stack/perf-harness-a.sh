#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: perf-harness-a.sh

HUB-106 variant A baseline: times today's per-run call pattern (one weld_run
list call, then one weld_test_reports call per returned row, fired 6 at a
time via Promise.all - today's real code path, capped by the browser's
HTTP/1.1 per-host connection limit) against the synthetic dataset
perf-seed.sh created. A sequential variant is also printed for context only
- it is not what the real page does. Read-only against NovApi - no code
changes. Logs in as the seeded synthetic test user automatically.

Env overrides: PERF_ROBOT_ID (default 900001), PERF_PER_PAGE (default 2000),
PERF_TRIALS (default 3, trial 1 counts as cold, the rest as warm).

Needs run-novhub.sh up's OpenSearch container, NovApi's own docker compose
stack running, and perf-seed.sh seed already run.
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
