#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/steps/plcsim.sh"

usage() {
  cat <<USAGE
Usage: weld.sh start|stop|status [--job REF] [--spool REF] [--weld REF]

Triggers a hot weld on PLCSIM's REST API (127.0.0.1:${PLCSIM_REST_PORT}), so NovData sees a
real weld run flow through to the browser - no plc-node or LUNA needed for this, REST alone
starts it. Needs PLCSIM running (./plcsim.sh start) and NovData listening (./novdata.sh start).

  start   sets the job/spool/weld references, then starts a hot weld (idempotent - if one is
          already running, leaves it running and says so).
  stop    stops a running weld (idempotent - no-op if nothing is running).
  status  reports whether a weld is running and the refs it's using. Changes nothing.

  --job REF    Work order reference the stream carries (default: a unique "weld-<timestamp>")
  --spool REF  Spool reference (default: "spool-1")
  --weld REF   Weld id reference (default: "1")
  Each is at most 50 bytes - PLCSIM truncates the stream field otherwise.

After a weld runs, reflect it in NovApp with ./sync.sh start.
USAGE
}

PLCSIM_REST_URL="http://127.0.0.1:${PLCSIM_REST_PORT}"

weld_status() {
  local weld
  weld="$(curl -s "$PLCSIM_REST_URL/api/weld")"
  echo "$weld"
  if echo "$weld" | grep -Eq '"hot_weld" *: *true'; then
    return 0
  fi
  return 1
}

ACTION="${1:-}"
[ "$ACTION" = "-h" ] || [ "$ACTION" = "--help" ] && { usage; exit 0; }
[ -n "$ACTION" ] || { usage; exit 1; }
shift || true

JOB_REF=""
SPOOL_REF="spool-1"
WELD_REF="1"
while [ $# -gt 0 ]; do
  case "$1" in
    --job) JOB_REF="$2"; shift 2 ;;
    --spool) SPOOL_REF="$2"; shift 2 ;;
    --weld) WELD_REF="$2"; shift 2 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done
[ -n "$JOB_REF" ] || JOB_REF="weld-$(date -u +%Y%m%dT%H%M%SZ)"

if ! listening "$PLCSIM_REST_PORT"; then
  error "FAILED: PLCSIM's REST API is not listening on $PLCSIM_REST_PORT - run ./plcsim.sh start first"
  exit 1
fi

case "$ACTION" in
  start)
    curl -s -X PUT "$PLCSIM_REST_URL/api/mem/Work_Ref" -H 'content-type: application/json' -d "{\"value\":\"$JOB_REF\"}" >/dev/null
    curl -s -X PUT "$PLCSIM_REST_URL/api/mem/Spool_Ref" -H 'content-type: application/json' -d "{\"value\":\"$SPOOL_REF\"}" >/dev/null
    curl -s -X PUT "$PLCSIM_REST_URL/api/mem/Weld_Ref" -H 'content-type: application/json' -d "{\"value\":\"$WELD_REF\"}" >/dev/null
    log "ok: refs set (job=$JOB_REF spool=$SPOOL_REF weld=$WELD_REF)"
    if weld_status >/dev/null; then
      log "already running: a hot weld is in progress"
    else
      curl -s -X POST "$PLCSIM_REST_URL/api/weld/hot_weld" >/dev/null
      log "created: hot weld started"
    fi
    weld_status || true
    ;;
  stop)
    if weld_status >/dev/null; then
      curl -s -X POST "$PLCSIM_REST_URL/api/weld/stop" >/dev/null
      log "stopped: hot weld"
    else
      log "already stopped: no weld running"
    fi
    ;;
  status)
    if weld_status >/dev/null; then
      log "ok: a hot weld is running"
    else
      log "ok: no weld running"
    fi
    ;;
  *)
    error "Unknown action: $ACTION (expected start|stop|status)"
    exit 1
    ;;
esac
