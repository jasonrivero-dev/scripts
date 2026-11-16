#!/usr/bin/env bash
set -euo pipefail

RESET_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RESET_SCRIPT_DIR/lib/common.sh"
source "$NOVHUB_ROOT/steps/novapi.sh"
source "$NOVHUB_ROOT/steps/novdata.sh"
source "$NOVHUB_ROOT/steps/opensearch.sh"

usage() {
  cat <<USAGE
Usage: reset.sh [--novapi-db] [--novdata-db] [--opensearch] [--state] [--all]

Selectively wipe containers/data novhub-local-stack touches, for a clean slate before
repeated local testing. No flags: print this usage and do nothing.
USAGE
}

reset_novapi_db() {
  if have_container "$NOVAPI_DB_CONTAINER"; then
    (cd "$NOVAPI_REPO" && docker compose rm -f -s "$NOVAPI_DB_SERVICE" >/dev/null)
    log "removed: $NOVAPI_DB_CONTAINER"
  else
    log "already absent: $NOVAPI_DB_CONTAINER"
  fi
}

reset_novdata_db() {
  if have_container "$NOVDATA_CONTAINER"; then
    docker rm -f "$NOVDATA_CONTAINER" >/dev/null
    log "removed: $NOVDATA_CONTAINER"
  else
    log "already absent: $NOVDATA_CONTAINER"
  fi
}

reset_opensearch() {
  if have_container "$OPENSEARCH_CONTAINER"; then
    docker rm -f "$OPENSEARCH_CONTAINER" >/dev/null
    log "removed: $OPENSEARCH_CONTAINER (index $OPENSEARCH_INDEX included)"
  else
    log "already absent: $OPENSEARCH_CONTAINER"
  fi
}

reset_state() {
  local name
  for name in novdata novapi; do
    if is_running "$name"; then
      stop_background "$name"
    fi
  done
  if [ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
    rm -rf "${STATE_DIR:?}"/*
    log "cleared: $STATE_DIR"
  else
    log "already clear: $STATE_DIR"
  fi
}

if [ "$#" -eq 0 ]; then
  usage
  exit 0
fi

for arg in "$@"; do
  case "$arg" in
    --novapi-db) reset_novapi_db ;;
    --novdata-db) reset_novdata_db ;;
    --opensearch) reset_opensearch ;;
    --state) reset_state ;;
    --all)
      reset_novapi_db
      reset_novdata_db
      reset_opensearch
      reset_state
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      error "unknown option: $arg"
      usage
      exit 1
      ;;
  esac
done
