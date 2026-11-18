#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: cloud-bastion-check.sh --env dev|test

HUB-106: a plain TCP reachability check FROM the cat-dev bastion to one
environment's DB (port 5432) and OpenSearch (port 443) hosts, using
exec_ubuntu (bashrc/.functions) - never a bare ssh/nc command. Hosts are
read from .state/secrets/novai-<env>/{DB,OPENSEARCH}.secrets at run time
and never printed by this script (exec_ubuntu's own "Running on ..."
line does echo the command it sends, which includes the host - that's
your own terminal showing your own data, not this script logging it).

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

BASTION_FUNCTIONS="$HOME/dev/scripts/bashrc/.functions"
[ -f "$BASTION_FUNCTIONS" ] || { error "not found: $BASTION_FUNCTIONS"; exit 1; }
# shellcheck disable=SC1090
source "$BASTION_FUNCTIONS" >/dev/null

# 5s is enough for an open port (fast) or an active refuse/reset (also fast); it only risks
# masking a successful-but-slow connect as "not reachable". 10s is a cheap safety margin for
# that case without meaningfully slowing down the common fast-fail case. Overridable.
TIMEOUT_S="${CLOUD_BASTION_CHECK_TIMEOUT_S:-10}"

log "checking '${ENV_NAME}' DB host:5432 from the cat-dev bastion..."
if exec_ubuntu cat-dev "timeout ${TIMEOUT_S} bash -c '</dev/tcp/${DB_HOST}/5432' && echo __TCP_OPEN__ || echo __TCP_CLOSED__" 2>&1 | tee /dev/stderr | grep -q __TCP_OPEN__; then
  log "'${ENV_NAME}' DB host:5432 - reachable from the bastion"
else
  log "'${ENV_NAME}' DB host:5432 - NOT reachable from the bastion"
fi

log "checking '${ENV_NAME}' OpenSearch host:443 from the cat-dev bastion..."
if exec_ubuntu cat-dev "timeout ${TIMEOUT_S} bash -c '</dev/tcp/${ES_HOST}/443' && echo __TCP_OPEN__ || echo __TCP_CLOSED__" 2>&1 | tee /dev/stderr | grep -q __TCP_OPEN__; then
  log "'${ENV_NAME}' OpenSearch host:443 - reachable from the bastion"
else
  log "'${ENV_NAME}' OpenSearch host:443 - NOT reachable from the bastion"
fi
