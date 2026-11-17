#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: perf-ingester-seed.sh [seed|remove|seed-reports]

HUB-106: seed (or remove) the minimal NovApi Postgres rows opensearch-ingester
needs - 2 synthetic robots (ids 910001-910002, overridable: PERF_ING_ROBOT_ID_START,
PERF_ING_ROBOT_COUNT) + one matching weld_monitoring_presets row each. Does NOT
write OpenSearch docs or weld_presets_associations - run perf-ingester-load.sh
for that, which exercises the ingester's own preset-matching code.

  seed          create the rows (no-op, prints "already seeded", if present)
  remove        delete those rows plus associations and weld_test_reports
  seed-reports  create one weld_test_reports row per run already associated
                (needed for NovApi's weld_test_reports(/batch) endpoints to
                return anything) - run this after perf-ingester-load.sh
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

NOVAPI_REPO="${NOVAPI_REPO:-$HOME/dev/NovApi}"
VENV_DIR="$NOVHUB_ROOT/.venv"
if [ -d "$VENV_DIR" ]; then
  log "already exists: $VENV_DIR"
else
  python3 -m venv "$VENV_DIR"
  log "created: $VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -q -r "$NOVHUB_ROOT/requirements.txt"

NOVAPI_DB_PASSWORD="$(sed -n '/^  db_cloud_dev:/,/^  [a-z_]*:/p' "$NOVAPI_REPO/docker-compose.yml" \
  | grep 'POSTGRES_PASSWORD=' | sed -E 's/.*POSTGRES_PASSWORD=//')"
if [ -z "$NOVAPI_DB_PASSWORD" ]; then
  error "Could not read POSTGRES_PASSWORD for db_cloud_dev from $NOVAPI_REPO/docker-compose.yml"
  exit 1
fi

NOVAPI_DB_PASSWORD="$NOVAPI_DB_PASSWORD" "$VENV_DIR/bin/python" "$NOVHUB_ROOT/perf-ingester-seed.py" "$1"
