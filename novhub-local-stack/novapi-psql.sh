#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: novapi-psql.sh [psql-args...]

Opens psql against NovApi's own Postgres (cloud_db_dev / swrdb_aggr). No
password needed - it runs inside the container via docker compose exec,
which uses local trust auth, not a network connection.

With no args: interactive psql prompt.
With args: run as a one-shot psql command, e.g.:
  ./novhub-local-stack/novapi-psql.sh -c "select count(*) from weld_test_reports"
USAGE
  exit 0
fi

NOVAPI_REPO="${NOVAPI_REPO:-$HOME/dev/NovApi}"
cd "$NOVAPI_REPO"
exec docker compose exec db_cloud_dev psql -U postgres -d swrdb_aggr "$@"
