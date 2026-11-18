#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: cloud-tunnel.sh open|status|close --env dev|test

HUB-106: a read-only SSH local-port-forward tunnel through the cat-dev
bastion to one environment's DB (real port 5432) and OpenSearch (real
port 443) hosts - nothing else reaches them for us. Hosts are read at
run time from .state/secrets/novai-<env>/{DB,OPENSEARCH}.secrets (never
printed, never hardcoded). Binds 127.0.0.1 only. Idempotent: "open" on an
already-open tunnel prints "already open" and changes nothing; "close" on
a closed one prints "already closed".

  open    start the tunnel in the background (two forwards)
  status  "open" (with its pid) or "closed"
  close   stop it

  --env dev|test   which environment's secrets/ports to use

Local ports come from cloud-tunnel-ports.env (git-ignored, auto-created
from the committed cloud-tunnel-ports.env.example on first run - non-
secret, just port numbers, chosen clear of this stack's own local ports).

Refuses up front if the bastion's SSH key is not exactly 0600, or if
either secrets file is missing its "host" key.

cat-dev's host/user/key come from ~/dev/scripts/bashrc/.functions (the
same place connect_ubuntu/cp_ubuntu/exec_ubuntu read them from) - this
tool only adds port-forwarding, which those don't do.

Note: this bastion is the one explored for dev. Whether it also reaches
test's DB/OpenSearch hosts is unconfirmed - run cloud-bastion-check.sh
--env test first if you haven't already.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ACTION="${1:-}"
shift || true
case "$ACTION" in
  open | status | close) ;;
  *) error "first argument must be open, status, or close"; exit 1 ;;
esac

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

ensure_cloud_tunnel_ports
if [ "$ENV_NAME" = "dev" ]; then
  DB_LOCAL_PORT="$(cloud_tunnel_port_get DEV_DB_LOCAL_PORT)"
  ES_LOCAL_PORT="$(cloud_tunnel_port_get DEV_OPENSEARCH_LOCAL_PORT)"
else
  DB_LOCAL_PORT="$(cloud_tunnel_port_get TEST_DB_LOCAL_PORT)"
  ES_LOCAL_PORT="$(cloud_tunnel_port_get TEST_OPENSEARCH_LOCAL_PORT)"
fi
[ -n "$DB_LOCAL_PORT" ] || { error "no local DB port configured for '$ENV_NAME' in $CLOUD_TUNNEL_PORTS_FILE"; exit 1; }
[ -n "$ES_LOCAL_PORT" ] || { error "no local OpenSearch port configured for '$ENV_NAME' in $CLOUD_TUNNEL_PORTS_FILE"; exit 1; }

TUNNEL_NAME="cloud-tunnel-${ENV_NAME}"

if [ "$ACTION" = "status" ]; then
  if is_running "$TUNNEL_NAME"; then
    log "open (pid $(cat "$STATE_DIR/${TUNNEL_NAME}.pid")) - 127.0.0.1:${DB_LOCAL_PORT} (DB), 127.0.0.1:${ES_LOCAL_PORT} (OpenSearch)"
  else
    log "closed"
  fi
  exit 0
fi

if [ "$ACTION" = "close" ]; then
  if is_running "$TUNNEL_NAME"; then
    stop_background "$TUNNEL_NAME"
  else
    log "already closed"
  fi
  rm -f "$STATE_DIR/${TUNNEL_NAME}.ssh_config"
  exit 0
fi

# ACTION = open
if is_running "$TUNNEL_NAME"; then
  log "already open (pid $(cat "$STATE_DIR/${TUNNEL_NAME}.pid"))"
  exit 0
fi

BASTION_FUNCTIONS="$HOME/dev/scripts/bashrc/.functions"
[ -f "$BASTION_FUNCTIONS" ] || { error "not found: $BASTION_FUNCTIONS"; exit 1; }
# Only the two cat-dev constants, not the whole personal dotfile - see bashrc/.functions'
# _resolve_server for the single source of truth this mirrors (its cat-dev case also sets
# user=ec2-user, which isn't a standalone constant there, so it's repeated here).
eval "$(grep -E '^(CAT_DEV_BASTION_HOST|CAT_DEV_BASTION_KEY)=' "$BASTION_FUNCTIONS")"
BASTION_USER="ec2-user"
if [ -z "${CAT_DEV_BASTION_HOST:-}" ] || [ -z "${CAT_DEV_BASTION_KEY:-}" ]; then
  error "could not read CAT_DEV_BASTION_HOST/CAT_DEV_BASTION_KEY from $BASTION_FUNCTIONS"
  exit 1
fi
require_0600 "$CAT_DEV_BASTION_KEY" "bastion key"

SECRETS_DIR="$NOVHUB_ROOT/.state/secrets/novai-${ENV_NAME}"
DB_FILE="$SECRETS_DIR/DB.secrets"
ES_FILE="$SECRETS_DIR/OPENSEARCH.secrets"
[ -f "$DB_FILE" ] || { error "missing: $DB_FILE"; exit 1; }
[ -f "$ES_FILE" ] || { error "missing: $ES_FILE"; exit 1; }

DB_HOST_RAW="$(secrets_kv_get "$DB_FILE" host)"
ES_HOST_RAW="$(secrets_kv_get "$ES_FILE" host)"
[ -n "$DB_HOST_RAW" ] || { error "no 'host' key found in $DB_FILE"; exit 1; }
[ -n "$ES_HOST_RAW" ] || { error "no 'host' key found in $ES_FILE"; exit 1; }

# The file's host value may carry a scheme/path/port (e.g. "https://.../") - normalize_host
# strips that down to a bare hostname; an invalid result is a parse error, never silently
# used to build a tunnel to nowhere.
DB_HOST="$(normalize_host "$DB_HOST_RAW")"
ES_HOST="$(normalize_host "$ES_HOST_RAW")"
[ -n "$DB_HOST" ] || { error "$DB_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port"; exit 1; }
[ -n "$ES_HOST" ] || { error "$ES_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port"; exit 1; }

# Host/port values go in this 0600 SSH config file, never on ssh's own command line - keeps
# them out of `ps` output, unlike passing -L arguments directly.
SSH_CONFIG="$STATE_DIR/${TUNNEL_NAME}.ssh_config"
cat > "$SSH_CONFIG" <<EOF
Host $TUNNEL_NAME
  HostName $CAT_DEV_BASTION_HOST
  User $BASTION_USER
  IdentityFile $CAT_DEV_BASTION_KEY
  IdentitiesOnly yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  LocalForward 127.0.0.1:${DB_LOCAL_PORT} ${DB_HOST}:5432
  LocalForward 127.0.0.1:${ES_LOCAL_PORT} ${ES_HOST}:443
EOF
chmod 600 "$SSH_CONFIG"

start_background "$TUNNEL_NAME" ssh -F "$SSH_CONFIG" -N "$TUNNEL_NAME"

deadline=$((SECONDS + 15))
while true; do
  if listening "$DB_LOCAL_PORT" && listening "$ES_LOCAL_PORT"; then
    log "created: tunnel open - 127.0.0.1:${DB_LOCAL_PORT} (DB), 127.0.0.1:${ES_LOCAL_PORT} (OpenSearch)"
    exit 0
  fi
  if ! is_running "$TUNNEL_NAME"; then
    error "tunnel exited before both ports came up - see $STATE_DIR/${TUNNEL_NAME}.log (the bastion may not reach one of these hosts)"
    rm -f "$SSH_CONFIG"
    exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    error "timed out waiting for both ports - see $STATE_DIR/${TUNNEL_NAME}.log"
    stop_background "$TUNNEL_NAME"
    rm -f "$SSH_CONFIG"
    exit 1
  fi
  sleep 1
done
