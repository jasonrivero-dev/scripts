#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: perf-ingester-load.sh [go-run-flags...]

HUB-106: runs opensearch-ingester's own RouteAndProcess, in-process, over
synthetic Hermit V2 payloads built from a REAL sample file as the structural
template (see ~/dev/opensearch-ingester/cmd/perfload) - that file is only
ever read, never copied or committed anywhere. Writes real-shaped OpenSearch
docs + weld_presets_associations (via the ingester's own preset-matching
code) to ES_INDEX (default: novhub-local-ingester, a NEW index - does not
touch novhub-local or anything perf-seed.sh created).

Prereqs: ./novhub-local-stack/perf-ingester-seed.sh seed (robot + preset rows),
the local OpenSearch container, NovApi's own docker compose Postgres.

Required: -template <path to a real Hermit V2 JSON file>. Other flags are
passed through to the Go program, e.g.:
  ./novhub-local-stack/perf-ingester-load.sh -template /path/to/real_sample.json \
    -robot-id-start 910001 -robot-count 2 -runs-per-robot 10 -points-per-run 3000

Env overrides: ES_HOST (default http://127.0.0.1:9200), ES_INDEX (default
novhub-local-ingester), NOVAPI_REPO (for the Postgres password lookup).
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

NOVAPI_REPO="${NOVAPI_REPO:-$HOME/dev/NovApi}"
INGESTER_REPO="${INGESTER_REPO:-$HOME/dev/opensearch-ingester}"

NOVAPI_DB_PASSWORD="$(sed -n '/^  db_cloud_dev:/,/^  [a-z_]*:/p' "$NOVAPI_REPO/docker-compose.yml" \
  | grep 'POSTGRES_PASSWORD=' | sed -E 's/.*POSTGRES_PASSWORD=//')"
if [ -z "$NOVAPI_DB_PASSWORD" ]; then
  error "Could not read POSTGRES_PASSWORD for db_cloud_dev from $NOVAPI_REPO/docker-compose.yml"
  exit 1
fi

cd "$INGESTER_REPO"
ES_HOST="${ES_HOST:-http://127.0.0.1:9200}" \
  ES_INDEX="${ES_INDEX:-novhub-local-ingester}" \
  OS_LOCAL=true \
  REGION=us-west-2 \
  PG_DSN="host=127.0.0.1 port=5433 dbname=swrdb_aggr user=postgres password=$NOVAPI_DB_PASSWORD sslmode=disable" \
  go run ./cmd/perfload "$@"
