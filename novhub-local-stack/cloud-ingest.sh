#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: cloud-ingest.sh --env dev [--robot-id ID] [--probe | --runs N] [--dry-run] --template <path>
       cloud-ingest.sh --env dev [--robot-id ID] --remove [--count N] [--confirm-delete]

HUB-106: adds synthetic weld_run data to a dev robot via opensearch-ingester's
perfload, through cloud-tunnel.sh. Full walkthrough, safety model, and worked
examples: docs/HUB-106-DEV-INGEST-AND-PERFORMANCE-RUNBOOK.md

Refuses up front unless: both tunnel forwards are open, the dev /etc/hosts
mapping exists, the AWS SSO session is live, the target robot exists in
NovApi, and a pre/post audit of OpenSearch + Postgres passes - no flag
bypasses the audit.

  --robot-id ID     target robot (default: DEV_INGEST_ROBOT_ID in
                    cloud-env.env); must exist in NovApi
  --probe           ingest exactly 1 run, with verification output
  --runs N          ingest exactly N runs, never capped (no --probe/--runs:
                    ingest up to DEFAULT_TARGET_TOTAL in cloud-ingest.py)
  --dry-run         print the plan, write nothing
  --template PATH   a real Hermit V2 sample file; required for a real ingest
  --remove [--count N] [--confirm-delete]
                    delete synthetic data, scoped to this tool's own
                    job_id/run_id range - all of it, or just the N most
                    recently added runs. Dry by default; --confirm-delete
                    requires typing the robot id back.

Combined ingester output is scrubbed and logged under .state/cloud-ingest-logs/.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ENV_NAME=""
ROBOT_ID_OVERRIDE=""
PY_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --robot-id) ROBOT_ID_OVERRIDE="$2"; shift 2 ;;
    --dry-run|--remove|--confirm-delete|--probe) PY_ARGS+=("$1"); shift ;;
    --runs|--count) PY_ARGS+=("$1" "$2"); shift 2 ;;
    --template) PY_ARGS+=("--template" "$2"); shift 2 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -n "$ROBOT_ID_OVERRIDE" ] && ! [[ "$ROBOT_ID_OVERRIDE" =~ ^[0-9]+$ ]]; then
  error "--robot-id must be a positive integer"
  exit 1
fi

if [ "$ENV_NAME" != "dev" ]; then
  error "--env dev only - test is QA's and off limits for this tool"
  exit 1
fi

ensure_cloud_env_config
AWS_REGION_CFG="$(cloud_env_get DEV_AWS_REGION)"
AWS_PROFILE_CFG="$(cloud_env_get DEV_AWS_PROFILE)"
INGEST_ROBOT_ID_CFG="${ROBOT_ID_OVERRIDE:-$(cloud_env_get DEV_INGEST_ROBOT_ID)}"
[ -n "$AWS_REGION_CFG" ] || { error "no AWS region configured for 'dev' in $CLOUD_ENV_CONFIG_FILE"; exit 1; }
[ -n "$AWS_PROFILE_CFG" ] || { error "no AWS profile configured for 'dev' in $CLOUD_ENV_CONFIG_FILE"; exit 1; }
[ -n "$INGEST_ROBOT_ID_CFG" ] || { error "no DEV_INGEST_ROBOT_ID configured in $CLOUD_ENV_CONFIG_FILE"; exit 1; }
require_aws_credentials_file_0600

ROBOT_EXISTS="$("$SCRIPT_DIR/perf-rank-robots.sh" --target "$ENV_NAME" --robot-exists "$INGEST_ROBOT_ID_CFG")"
[ "$ROBOT_EXISTS" = "yes" ] || { error "robot $INGEST_ROBOT_ID_CFG does not exist in NovApi for '$ENV_NAME'"; exit 1; }

is_running "cloud-tunnel-${ENV_NAME}-db" || { error "DB forward for '$ENV_NAME' is not open - run: ./cloud-tunnel.sh open --env $ENV_NAME"; exit 1; }
is_running "cloud-tunnel-${ENV_NAME}-es" || { error "OpenSearch forward for '$ENV_NAME' is not open - run: ./cloud-tunnel.sh open --env $ENV_NAME"; exit 1; }

SECRETS_DIR="$NOVHUB_ROOT/.state/secrets/novai-${ENV_NAME}"
ES_FILE="$SECRETS_DIR/OPENSEARCH.secrets"
[ -f "$ES_FILE" ] || { error "missing: $ES_FILE"; exit 1; }
ES_HOST_RAW="$(secrets_kv_get "$ES_FILE" host)"
[ -n "$ES_HOST_RAW" ] || { error "no 'host' key found in $ES_FILE"; exit 1; }
ES_HOST="$(normalize_host "$ES_HOST_RAW")"
[ -n "$ES_HOST" ] || { error "$ES_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port"; exit 1; }

ensure_cloud_tunnel_ports
DB_LOCAL_PORT="$(cloud_tunnel_port_get DEV_DB_LOCAL_PORT)"
ES_LOOPBACK="$(cloud_tunnel_port_get DEV_OPENSEARCH_LOOPBACK)"
[ -n "$ES_LOOPBACK" ] || { error "no OpenSearch loopback address configured for 'dev' in $CLOUD_TUNNEL_PORTS_FILE"; exit 1; }

EXPECTED_HOSTS_LINE="${ES_LOOPBACK} ${ES_HOST} $(cloud_hosts_marker "$ENV_NAME")"
grep -qF "$EXPECTED_HOSTS_LINE" /etc/hosts || { error "/etc/hosts line for '$ENV_NAME' is missing or stale - run: ./cloud-hosts.sh add --env $ENV_NAME"; exit 1; }

INGESTER_REPO="${INGESTER_REPO:-$HOME/dev/opensearch-ingester}"
[ -d "$INGESTER_REPO" ] || { error "not found: $INGESTER_REPO"; exit 1; }

VENV_DIR="$NOVHUB_ROOT/.venv"
if [ -d "$VENV_DIR" ]; then
  log "already exists: $VENV_DIR"
else
  python3 -m venv "$VENV_DIR"
  log "created: $VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -q -r "$NOVHUB_ROOT/requirements.txt"

export CLOUD_INGEST_ENV="$ENV_NAME"
export CLOUD_INGEST_SECRETS_DIR="$SECRETS_DIR"
export CLOUD_INGEST_DB_LOCAL_PORT="$DB_LOCAL_PORT"
export CLOUD_INGEST_ES_LOOPBACK="$ES_LOOPBACK"
export CLOUD_INGEST_AWS_REGION="$AWS_REGION_CFG"
export CLOUD_INGEST_AWS_PROFILE="$AWS_PROFILE_CFG"
export CLOUD_INGEST_ROBOT_ID="$INGEST_ROBOT_ID_CFG"
export CLOUD_INGEST_INGESTER_REPO="$INGESTER_REPO"
export CLOUD_INGEST_LOG_DIR="$STATE_DIR/cloud-ingest-logs"

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/cloud-ingest.py" "${PY_ARGS[@]}"
