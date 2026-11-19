#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: perf-slowlog.sh [on|off|status]

HUB-106: toggles slow-query logging at threshold 0ms (log every query) on
the local OpenSearch index and the local NovApi Postgres container - local
containers only, idempotent, off by default. Turn on only while measuring,
then off - at threshold 0 these logs are noisy (every single query).

  on      OpenSearch: PUT .../_settings slowlog thresholds to 0ms.
          Postgres:   ALTER SYSTEM SET log_min_duration_statement = 0,
                      reload (no restart needed).
  off     Resets both to their defaults (slowlog thresholds to null,
          log_min_duration_statement reset).
  status  Prints the current value of both, changes nothing.

Read the results with: docker logs os-local (lines "i.s.s.query"/"i.s.s.fetch",
field took_millis) and docker logs cloud_db_dev (lines "duration: N ms
statement: ...") - or use perf-correlate.sh to combine both with NovApi's
own morgan log into one per-endpoint table.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

NOVAPI_REPO="${NOVAPI_REPO:-$HOME/dev/NovApi}"
OS_INDEX="${OS_INDEX:-novhub-local-ingester}"
OS_PORT="${OS_PORT:-9200}"
PG_CONTAINER="cloud_db_dev"

os_get_threshold() {
  curl -s "http://127.0.0.1:${OS_PORT}/${OS_INDEX}/_settings?flat_settings=true" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); s=list(d.values())[0]['settings']; print(s.get('index.search.slowlog.threshold.query.warn','-1'))"
}

pg_get_threshold() {
  (cd "$NOVAPI_REPO" && docker compose exec -T db_cloud_dev psql -U postgres -d swrdb_aggr -tAc \
    "show log_min_duration_statement;") | tr -d '[:space:]'
}

case "$1" in
  status)
    log "OpenSearch slowlog threshold: $(os_get_threshold)"
    log "Postgres log_min_duration_statement: $(pg_get_threshold)"
    ;;
  on)
    if [ "$(os_get_threshold)" = "0ms" ]; then
      log "already on: OpenSearch slowlog (0ms)"
    else
      curl -s -X PUT "http://127.0.0.1:${OS_PORT}/${OS_INDEX}/_settings" -H 'Content-Type: application/json' \
        -d '{"index.search.slowlog.threshold.query.warn":"0ms","index.search.slowlog.threshold.fetch.warn":"0ms"}' >/dev/null
      log "created: OpenSearch slowlog on (0ms) for $OS_INDEX"
    fi
    if [ "$(pg_get_threshold)" = "0" ]; then
      log "already on: Postgres log_min_duration_statement (0)"
    else
      (cd "$NOVAPI_REPO" && docker compose exec -T db_cloud_dev psql -U postgres -d swrdb_aggr -v ON_ERROR_STOP=1 \
        -c "ALTER SYSTEM SET log_min_duration_statement = 0;" -c "SELECT pg_reload_conf();") >/dev/null
      log "created: Postgres log_min_duration_statement on (0) for $PG_CONTAINER"
    fi
    warn "noisy at this threshold - turn off with 'perf-slowlog.sh off' once done measuring"
    ;;
  off)
    if [ "$(os_get_threshold)" = "-1" ]; then
      log "already off: OpenSearch slowlog"
    else
      curl -s -X PUT "http://127.0.0.1:${OS_PORT}/${OS_INDEX}/_settings" -H 'Content-Type: application/json' \
        -d '{"index.search.slowlog.threshold.query.warn":null,"index.search.slowlog.threshold.fetch.warn":null}' >/dev/null
      log "reset: OpenSearch slowlog off for $OS_INDEX"
    fi
    pg_val="$(pg_get_threshold)"
    if [ "$pg_val" = "-1" ]; then
      log "already off: Postgres log_min_duration_statement"
    else
      (cd "$NOVAPI_REPO" && docker compose exec -T db_cloud_dev psql -U postgres -d swrdb_aggr -v ON_ERROR_STOP=1 \
        -c "ALTER SYSTEM RESET log_min_duration_statement;" -c "SELECT pg_reload_conf();") >/dev/null
      log "reset: Postgres log_min_duration_statement off for $PG_CONTAINER"
    fi
    ;;
  *)
    error "Unknown action: $1 (expected on|off|status)"
    exit 1
    ;;
esac
