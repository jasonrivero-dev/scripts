#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: cloud-ingest.sh --env dev [--probe | --runs N] [--dry-run] --template <path>
       cloud-ingest.sh --env dev --remove [--confirm-delete]

HUB-106: wraps opensearch-ingester's perfload tool to add synthetic runs to
dev's robot (DEV_INGEST_ROBOT_ID in cloud-env.env), through cloud-tunnel.sh,
so robot reaches about 2,260 total weld_run entries (test's NovAI-1555 has
2,259). Host/index/DB values are read from the secrets files and reach the
ingester process only through its own environment - never printed, never a
command-line argument, never typed by you. ES_HOST never carries a port -
cloud-tunnel.sh's OpenSearch forward is pinned to the real port (443) on
this env's own loopback address specifically so the signed Host header
matches what AWS recomputes server-side (a tunnel on a high port was the
real cause of a prior 403 "signature we calculated does not match").

The owner's own decision: probe with exactly one real run first, verify,
then do the rest - start with --probe, not a full run.

Refuses up front, before anything runs, unless:
  - both forwards for this env are open (cloud-tunnel.sh open --env <env>)
  - the /etc/hosts line for this env is present (cloud-hosts.sh add --env <env>)
  - the AWS profile's SSO session is live right now (a real STS call)
  - DEV_INGEST_ROBOT_ID is set in cloud-env.env
  - robot's current total is read fresh each run (the "daemon-free path" -
    perf-rank-robots.sh --target <env> --robot-id <id>), never assumed
  - OpenSearch's mapping and the synthetic run IDs in OpenSearch and
    Postgres are audited before and after each add. A complete requested
    batch is a verified no-op; an empty synthetic state may be ingested;
    partial or conflicting state stops before writing. There is no
    override that can bypass this check.

  --probe           ingest exactly ONE real run (OpenSearch docs + the
                    Postgres association), then print: the OpenSearch raw
                    document count for this robot before/after, the
                    Postgres association count, and what perf-rank-robots
                    shows - so you can confirm it actually worked before
                    committing to the rest. If this passes and more are
                    needed, prints the --remove command to clear the
                    probe's data and the --runs N command for the full
                    remaining amount - never a bare "continue" command,
                    since this run's data still exists and a follow-up
                    would duplicate it.
  --runs N          ingest exactly N real runs instead of "whatever's left
                    to reach ~2,260" - must be a positive integer, capped
                    (with a note) at however many are left. Same
                    verification output as --probe, generalized to N.
                    Mutually exclusive with --probe (which is --runs 1).
                    Run-id base is always the same fixed value, and every
                    invocation's run index restarts at 1 against it - a
                    larger request after a smaller completed batch is
                    therefore a partial-state conflict. Remove the existing
                    batch before ingesting a different size.
  --dry-run         print the full plan and stop - nothing written, no
                    values in the printed plan.
  --template PATH   a real Hermit V2 sample file - same shape
                    perf-ingester-load.sh already uses locally, NOT a test
                    fixture. Required for any real (non---dry-run) ingest.

The ingester's own combined output is scrubbed (never an ARN, never an
echoed x-amz-security-token/Authorization/AWSAccessKey value - confirmed
for real that a signature-mismatch 403 can echo the token back) and
logged to a 0600 file under .state/cloud-ingest-logs/, whose path is
printed - read that for the first real errors instead of the terminal
scrollback.

If a matching weld_monitoring_presets row doesn't exist for the robot (the
Postgres association the ingester creates needs one to match), this stops
and prints the exact SQL as text instead - it never runs that INSERT
itself; the owner decides.

  --remove [--confirm-delete]
                    prints what would be deleted (OpenSearch delete_by_query
                    + a Postgres DELETE), scoped ONLY to this tool's own
                    synthetic job_id / run_id >= the run-id base - never
                    robot_id alone, since the robot also has real data.
                    A confirmed removal audits both stores first, attempts
                    both scoped deletions, and audits again; retries can
                    finish a partial delete. Exit is successful only when
                    both stores are verified clear.
                    The OpenSearch delete matches on job_id, not on run_id
                    or document _id, so it covers every synthetic document
                    regardless of how many duplicate invocations wrote
                    them (confirmed: the same job_id is written on every
                    document this tool ever creates for the robot, even
                    though each invocation's document _id differs). Dry
                    by default; --confirm-delete additionally requires
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
    --dry-run|--remove|--confirm-delete|--probe) PY_ARGS+=("$1"); shift ;;
    --runs) PY_ARGS+=("--runs" "$2"); shift 2 ;;
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
export CLOUD_INGEST_RANK_SCRIPT="$SCRIPT_DIR/perf-rank-robots.sh"
export CLOUD_INGEST_LOG_DIR="$STATE_DIR/cloud-ingest-logs"

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/cloud-ingest.py" "${PY_ARGS[@]}"
