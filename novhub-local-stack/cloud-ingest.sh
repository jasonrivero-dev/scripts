#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: cloud-ingest.sh --env dev [--dry-run] [--force] [--template <path>]
       cloud-ingest.sh --env dev --remove [--confirm-delete]

HUB-106: wraps opensearch-ingester's perfload tool to add synthetic runs to
dev's robot (DEV_INGEST_ROBOT_ID in cloud-env.env), through cloud-tunnel.sh,
so robot reaches about 2,260 total weld_run entries (test's NovAI-1555 has
2,259). Host/index/DB values are read from the secrets files and reach the
ingester process only through its own environment - never printed, never a
command-line argument, never typed by you.

Refuses up front, before anything runs, unless:
  - the tunnel for this env is open (cloud-tunnel.sh open --env <env>)
  - the /etc/hosts line for this env is present (cloud-hosts.sh add --env <env>)
  - the AWS profile's SSO session is live right now (a real STS call)
  - DEV_INGEST_ROBOT_ID is set in cloud-env.env
  - robot's current total is read fresh each run (the "daemon-free path" -
    perf-rank-robots.sh --target <env> --robot-id <id>), never assumed
  - nothing with this tool's own synthetic job_id already exists for the
    robot (refuses "already ingested" unless --force)

  --dry-run         print the full plan (robot id, runs to add, points per
                    run, run-id base, spacing, resulting date span, what
                    gets written where) and stop - nothing written, no
                    values in the printed plan.
  --force           add more even if this tool's synthetic data already
                    exists for the robot.
  --template PATH   a real Hermit V2 sample file - same shape
                    perf-ingester-load.sh already uses locally, NOT a test
                    fixture. Required for a real (non---dry-run) ingest.

If a matching weld_monitoring_presets row doesn't exist for the robot (the
Postgres association the ingester creates needs one to match), this stops
and prints the exact SQL as text instead - it never runs that INSERT
itself; the owner decides.

  --remove [--confirm-delete]
                    prints what would be deleted (OpenSearch delete_by_query
                    + a Postgres DELETE), scoped ONLY to this tool's own
                    synthetic job_id / run_id >= the run-id base - never
                    robot_id alone, since the robot also has real data.
                    Dry by default; --confirm-delete additionally requires
                    typing the robot id back before anything is deleted.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ENV_NAME=""
PY_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --dry-run|--force|--remove|--confirm-delete) PY_ARGS+=("$1"); shift ;;
    --template) PY_ARGS+=("--template" "$2"); shift 2 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ "$ENV_NAME" != "dev" ]; then
  error "--env dev only - test is QA's and off limits for this tool"
  exit 1
fi

ensure_cloud_env_config
AWS_REGION_CFG="$(cloud_env_get DEV_AWS_REGION)"
AWS_PROFILE_CFG="$(cloud_env_get DEV_AWS_PROFILE)"
INGEST_ROBOT_ID_CFG="$(cloud_env_get DEV_INGEST_ROBOT_ID)"
[ -n "$AWS_REGION_CFG" ] || { error "no AWS region configured for 'dev' in $CLOUD_ENV_CONFIG_FILE"; exit 1; }
[ -n "$AWS_PROFILE_CFG" ] || { error "no AWS profile configured for 'dev' in $CLOUD_ENV_CONFIG_FILE"; exit 1; }
[ -n "$INGEST_ROBOT_ID_CFG" ] || { error "no DEV_INGEST_ROBOT_ID configured in $CLOUD_ENV_CONFIG_FILE"; exit 1; }
require_aws_credentials_file_0600

TUNNEL_NAME="cloud-tunnel-${ENV_NAME}"
is_running "$TUNNEL_NAME" || { error "tunnel for '$ENV_NAME' is not open - run: ./cloud-tunnel.sh open --env $ENV_NAME"; exit 1; }

SECRETS_DIR="$NOVHUB_ROOT/.state/secrets/novai-${ENV_NAME}"
ES_FILE="$SECRETS_DIR/OPENSEARCH.secrets"
[ -f "$ES_FILE" ] || { error "missing: $ES_FILE"; exit 1; }
ES_HOST_RAW="$(secrets_kv_get "$ES_FILE" host)"
[ -n "$ES_HOST_RAW" ] || { error "no 'host' key found in $ES_FILE"; exit 1; }
ES_HOST="$(normalize_host "$ES_HOST_RAW")"
[ -n "$ES_HOST" ] || { error "$ES_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port"; exit 1; }

EXPECTED_HOSTS_LINE="127.0.0.1 ${ES_HOST} $(cloud_hosts_marker "$ENV_NAME")"
grep -qF "$EXPECTED_HOSTS_LINE" /etc/hosts || { error "/etc/hosts line for '$ENV_NAME' is missing or stale - run: ./cloud-hosts.sh add --env $ENV_NAME"; exit 1; }

ensure_cloud_tunnel_ports
DB_LOCAL_PORT="$(cloud_tunnel_port_get DEV_DB_LOCAL_PORT)"
ES_LOCAL_PORT="$(cloud_tunnel_port_get DEV_OPENSEARCH_LOCAL_PORT)"

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
export CLOUD_INGEST_ES_LOCAL_PORT="$ES_LOCAL_PORT"
export CLOUD_INGEST_AWS_REGION="$AWS_REGION_CFG"
export CLOUD_INGEST_AWS_PROFILE="$AWS_PROFILE_CFG"
export CLOUD_INGEST_ROBOT_ID="$INGEST_ROBOT_ID_CFG"
export CLOUD_INGEST_INGESTER_REPO="$INGESTER_REPO"
export CLOUD_INGEST_RANK_SCRIPT="$SCRIPT_DIR/perf-rank-robots.sh"

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/cloud-ingest.py" "${PY_ARGS[@]}"
