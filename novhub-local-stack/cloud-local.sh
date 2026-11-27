#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: cloud-local.sh start|status|stop|restart --env dev

Runs this checkout's NovApi and NovApp against the existing dev Postgres and
OpenSearch tunnels. Both forwards and the OpenSearch hosts mapping must already
be in place. This command never opens or closes tunnels, changes application
checkouts, runs migrations, or writes/deletes dev data.

  start   verify dev access and start local NovApi/NovApp
  status  show only cloud-local managed process state
  stop    stop only cloud-local managed processes
  restart stop then start (both services down briefly); same dev access
          and port checks as start, same rollback as stop - no partial state
          left if either half fails. No NovApi-only restart: both always
          stop together.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/steps/cloud_local.sh"

ACTION="${1:-}"
shift || true
ENV_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env)
      [ $# -ge 2 ] || { error "--env requires a value"; exit 2; }
      ENV_NAME="$2"
      shift 2
      ;;
    *)
      error "unknown argument: $1"
      exit 2
      ;;
  esac
done

if [ "$ENV_NAME" != "dev" ]; then
  error "--env dev is required"
  exit 2
fi

case "$ACTION" in
  start) cloud_local_start "$ENV_NAME" ;;
  status) cloud_local_status "$ENV_NAME" ;;
  stop) cloud_local_stop "$ENV_NAME" ;;
  restart) cloud_local_restart "$ENV_NAME" ;;
  *)
    error "first argument must be start, status, stop, or restart"
    exit 2
    ;;
esac
