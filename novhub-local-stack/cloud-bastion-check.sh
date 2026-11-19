#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: cloud-bastion-check.sh --env dev|test

HUB-106: a plain TCP reachability check FROM the cat-dev bastion to one
environment's DB and OpenSearch hosts, using exec_ubuntu
(bashrc/.functions) - never a bare ssh/nc command. Host is read from
.state/secrets/novai-<env>/{DB,OPENSEARCH}.secrets at run time. Port: an
explicit :port in the host value itself if it has one, else OpenSearch
always falls back to 443 (its real HTTPS endpoint - never that file's
separate 'port' key, confirmed to be a different value, 9200, that is
not the endpoint) and DB falls back to its file's 'port' key (confirmed
correct there - 5432). Host/port aren't printed by this script itself
(exec_ubuntu's own "Running on ..." line does echo the command it sends,
which includes the host - that's your own terminal showing your own
data, not this script logging it).

We only explored the bastion for dev; whether it also reaches test's
hosts is unconfirmed - that is exactly what --env test checks here.

A host value that still doesn't look like a plain hostname after
stripping a scheme/path/port is a parse error - refuses with one line,
never runs a check against it (an invalid check is not a real answer).

  --env dev|test   which environment's hosts to check

Env override: CLOUD_BASTION_CHECK_TIMEOUT_S (default 10) - the per-host
TCP connect timeout on the bastion.
USAGE
  exit 0
fi

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
# strips that down to a bare hostname. A result that still isn't one is a parse error: never
# run a TCP check against it and call the outcome "NOT reachable" - that's not a real answer.
DB_HOST="$(normalize_host "$DB_HOST_RAW")"
ES_HOST="$(normalize_host "$ES_HOST_RAW")"
[ -n "$DB_HOST" ] || { error "$DB_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port - not running a check against it"; exit 1; }
[ -n "$ES_HOST" ] || { error "$ES_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port - not running a check against it"; exit 1; }

# Port: prefer an explicit :port in the host value itself (the real endpoint address) over
# the file's separate 'port' key - confirmed for OpenSearch, whose file's 'port' key is 9200
# while the managed domain's real HTTPS endpoint is 443, so a check built from the key alone
# probes the wrong port (HUB-106 real-run report). DB has no such mismatch (its 'port' key -
# 5432 - matches the real endpoint), so it still falls back to the key; OpenSearch falls back
# to 443 instead (its only real option over HTTPS).
DB_PORT="$(url_port "$DB_HOST_RAW")"
[ -n "$DB_PORT" ] || DB_PORT="$(secrets_kv_get "$DB_FILE" port)"
ES_PORT="$(url_port "$ES_HOST_RAW")"
[ -n "$ES_PORT" ] || ES_PORT=443
[[ "$DB_PORT" =~ ^[0-9]+$ ]] || { error "$DB_FILE: could not resolve a DB port (no :port in 'host', and 'port' key is missing or not a number)"; exit 1; }
[[ "$ES_PORT" =~ ^[0-9]+$ ]] || { error "internal error: ES_PORT resolved to '$ES_PORT'"; exit 1; }

BASTION_FUNCTIONS="$HOME/dev/scripts/bashrc/.functions"
[ -f "$BASTION_FUNCTIONS" ] || { error "not found: $BASTION_FUNCTIONS"; exit 1; }
# shellcheck disable=SC1090
source "$BASTION_FUNCTIONS" >/dev/null

# 5s is enough for an open port (fast) or an active refuse/reset (also fast); it only risks
# masking a successful-but-slow connect as "not reachable". 10s is a cheap safety margin for
# that case without meaningfully slowing down the common fast-fail case. Overridable.
TIMEOUT_S="${CLOUD_BASTION_CHECK_TIMEOUT_S:-10}"

log "checking '${ENV_NAME}' DB host:${DB_PORT} from the cat-dev bastion..."
if exec_ubuntu cat-dev "timeout ${TIMEOUT_S} bash -c '</dev/tcp/${DB_HOST}/${DB_PORT}' && echo __TCP_OPEN__ || echo __TCP_CLOSED__" 2>&1 | tee /dev/stderr | grep -q __TCP_OPEN__; then
  log "'${ENV_NAME}' DB host:${DB_PORT} - reachable from the bastion"
else
  log "'${ENV_NAME}' DB host:${DB_PORT} - NOT reachable from the bastion"
fi

log "checking '${ENV_NAME}' OpenSearch host:${ES_PORT} from the cat-dev bastion..."
if exec_ubuntu cat-dev "timeout ${TIMEOUT_S} bash -c '</dev/tcp/${ES_HOST}/${ES_PORT}' && echo __TCP_OPEN__ || echo __TCP_CLOSED__" 2>&1 | tee /dev/stderr | grep -q __TCP_OPEN__; then
  log "'${ENV_NAME}' OpenSearch host:${ES_PORT} - reachable from the bastion"
else
  log "'${ENV_NAME}' OpenSearch host:${ES_PORT} - NOT reachable from the bastion"
fi
