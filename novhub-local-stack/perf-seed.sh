#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: perf-seed.sh [seed|remove]

HUB-106: seed (or remove) a frozen synthetic dataset for NovApi/NovApp perf
testing - 10 synthetic robots (ids 900001-900010) x 2,000 runs = 20,000 runs,
one synthetic test user, one synthetic group. Writes directly to NovApi's own
Postgres (cloud_db_dev) and the local OpenSearch index - never through
LUNA/PLCSIM/plc-node or NovData.

  seed    create the dataset (no-op, prints "already seeded", if it exists)
  remove  delete exactly the tagged rows/docs this created (no-op if absent)

Needs NovApi's docker compose stack and the local OpenSearch container up
(./novhub-local-stack/run-novhub.sh up).
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

NOVAPI_REPO="${NOVAPI_REPO:-$HOME/dev/NovApi}"
VENV_DIR="$NOVHUB_ROOT/.venv"
REQUIREMENTS="$NOVHUB_ROOT/requirements.txt"
SEEDER="$NOVHUB_ROOT/perf-seed.py"

if [ -d "$VENV_DIR" ]; then
  log "already exists: $VENV_DIR"
else
  python3 -m venv "$VENV_DIR"
  log "created: $VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -q -r "$REQUIREMENTS"

# Same file NovApi's own docker-compose.yml already has this dev-only password in plaintext -
# read it from there instead of hardcoding it a second time.
NOVAPI_DB_PASSWORD="$(sed -n '/^  db_cloud_dev:/,/^  [a-z_]*:/p' "$NOVAPI_REPO/docker-compose.yml" \
  | grep 'POSTGRES_PASSWORD=' | sed -E 's/.*POSTGRES_PASSWORD=//')"
if [ -z "$NOVAPI_DB_PASSWORD" ]; then
  error "Could not read POSTGRES_PASSWORD for db_cloud_dev from $NOVAPI_REPO/docker-compose.yml"
  exit 1
fi

NOVAPI_REPO="$NOVAPI_REPO" NOVAPI_DB_PASSWORD="$NOVAPI_DB_PASSWORD" \
  "$VENV_DIR/bin/python" "$SEEDER" "$1"
