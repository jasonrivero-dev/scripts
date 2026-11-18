#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: cloud-hosts.sh add|remove --env dev|test

HUB-106: adds/removes exactly one /etc/hosts line mapping that
environment's real OpenSearch hostname to 127.0.0.1, so a request built
for the real hostname (for SNI + the correct Host header) actually lands
on cloud-tunnel.sh's local forward. The host comes from
.state/secrets/novai-<env>/OPENSEARCH.secrets at run time, never
hardcoded, never printed - only the resolved line itself is shown, since
that's the whole point of this tool (you're about to put it in a system
file).

Idempotent: "add" when the line is already there prints "already added"
and changes nothing; "remove" when it's already gone prints "already
removed". Uses a marker comment unique to this tool+env to find its own
line again later - never touches any other line in /etc/hosts. Needs
sudo only for the one step that actually rewrites /etc/hosts; everything
else runs as you.

Run cloud-hosts.sh remove --env <env> when you're done using
--via-hostname for that environment.
USAGE
  exit 0
fi

ACTION="${1:-}"
shift || true
case "$ACTION" in
  add | remove) ;;
  *) echo "first argument must be add or remove" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ENV_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done
case "$ENV_NAME" in
  dev | test) ;;
  *) error "--env dev|test is required"; exit 1 ;;
esac

ES_FILE="$NOVHUB_ROOT/.state/secrets/novai-${ENV_NAME}/OPENSEARCH.secrets"
[ -f "$ES_FILE" ] || { error "missing: $ES_FILE"; exit 1; }

ES_HOST_RAW="$(secrets_kv_get "$ES_FILE" host)"
[ -n "$ES_HOST_RAW" ] || { error "no 'host' key found in $ES_FILE"; exit 1; }
ES_HOST="$(normalize_host "$ES_HOST_RAW")"
[ -n "$ES_HOST" ] || { error "$ES_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port"; exit 1; }

MARKER="$(cloud_hosts_marker "$ENV_NAME")"
LINE="127.0.0.1 ${ES_HOST} ${MARKER}"

if [ "$ACTION" = "add" ]; then
  if grep -qF "$LINE" /etc/hosts; then
    log "already added"
    exit 0
  fi
  TMP_HOSTS="$(mktemp)"
  grep -vF "$MARKER" /etc/hosts > "$TMP_HOSTS" || true
  echo "$LINE" >> "$TMP_HOSTS"
  sudo cp "$TMP_HOSTS" /etc/hosts
  rm -f "$TMP_HOSTS"
  log "created: $LINE"
else
  if ! grep -qF "$MARKER" /etc/hosts; then
    log "already removed"
    exit 0
  fi
  TMP_HOSTS="$(mktemp)"
  grep -vF "$MARKER" /etc/hosts > "$TMP_HOSTS" || true
  sudo cp "$TMP_HOSTS" /etc/hosts
  rm -f "$TMP_HOSTS"
  log "removed"
fi
