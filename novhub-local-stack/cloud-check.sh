#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: cloud-check.sh --env dev|test [--via-hostname]

HUB-106: read-only credential check for one environment, through its
cloud-tunnel.sh tunnel (open it first - this refuses if it isn't).

  DB: connects to 127.0.0.1:<local port> with the secrets file's own
      name/username/password, runs SELECT 1 then SELECT COUNT(*) FROM
      robot.
  OpenSearch: cluster health + a count on the secrets file's index, tried
      two ways - (a) basic auth with the file's username/password, (b)
      AWS SigV4 via the default credential chain (how NovApi itself
      always connects - see osRepo/queries.js, it never uses the
      username/password it fetches). Reports which of (a)/(b) worked.
      For (b), also prints the SigV4 caller's identity reduced to
      account:role (no session name) - hand that to whoever manages the
      domain's fine-grained security role mapping if SigV4 is refused.
      If the profile's SSO token has expired, prints an "aws sso login"
      hint instead of a bare error.
  Security admin: whether the basic-auth login can administer the
      security plugin (GET rolesmapping + roles for opensearch-API-role)
      - reports status, the role NAME(s) found, and the NUMBER of
      backend roles mapped (never their ARNs).

Never prints a secret value anywhere, and never a full ARN (only
account number + role name, no session name) - only pass/fail, counts,
and a missing key's NAME if one is absent.

  --via-hostname   connect using the real OpenSearch hostname instead of
                   127.0.0.1 (same local port) - needs the owner to have
                   added a /etc/hosts line for that host -> 127.0.0.1
                   first (this script does not edit /etc/hosts). Without
                   this flag, the request already carries the correct
                   Host header for signing/routing either way - only try
                   --via-hostname if the default fails in a way that
                   looks like a TLS/SNI problem, not a signature or
                   credentials problem.

Region and credentials for the SigV4 attempt come from cloud-env.env
(git-ignored, auto-created from the committed cloud-env.env.example) -
never the ambient shell environment. Set DEV_AWS_REGION/DEV_AWS_PROFILE
(or TEST_...) there to a region code and a profile already configured
for the AWS CLI - SSO profiles (e.g. via `aws configure sso`) live in
~/.aws/config, static-key profiles in ~/.aws/credentials; never put a
raw key in either file yourself. Refuses with one line if region or
profile is missing for this --env, or if ~/.aws/credentials exists but
isn't exactly 0600 (that check only applies to credentials - ~/.aws/config
is non-secret profile metadata, left at 644 by the AWS CLI itself).
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ENV_NAME=""
VIA_HOSTNAME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --via-hostname) VIA_HOSTNAME=1; shift ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done
case "$ENV_NAME" in
  dev | test) ;;
  *) error "--env dev|test is required"; exit 1 ;;
esac

TUNNEL_NAME="cloud-tunnel-${ENV_NAME}"
if ! is_running "$TUNNEL_NAME"; then
  error "tunnel for '$ENV_NAME' is not open - run: ./cloud-tunnel.sh open --env $ENV_NAME"
  exit 1
fi

ensure_cloud_tunnel_ports
if [ "$ENV_NAME" = "dev" ]; then
  DB_LOCAL_PORT="$(cloud_tunnel_port_get DEV_DB_LOCAL_PORT)"
  ES_LOCAL_PORT="$(cloud_tunnel_port_get DEV_OPENSEARCH_LOCAL_PORT)"
else
  DB_LOCAL_PORT="$(cloud_tunnel_port_get TEST_DB_LOCAL_PORT)"
  ES_LOCAL_PORT="$(cloud_tunnel_port_get TEST_OPENSEARCH_LOCAL_PORT)"
fi

SECRETS_DIR="$NOVHUB_ROOT/.state/secrets/novai-${ENV_NAME}"
[ -d "$SECRETS_DIR" ] || { error "missing: $SECRETS_DIR"; exit 1; }

ensure_cloud_env_config
if [ "$ENV_NAME" = "dev" ]; then
  AWS_REGION_CFG="$(cloud_env_get DEV_AWS_REGION)"
  AWS_PROFILE_CFG="$(cloud_env_get DEV_AWS_PROFILE)"
else
  AWS_REGION_CFG="$(cloud_env_get TEST_AWS_REGION)"
  AWS_PROFILE_CFG="$(cloud_env_get TEST_AWS_PROFILE)"
fi
[ -n "$AWS_REGION_CFG" ] || { error "no AWS region configured for '$ENV_NAME' in $CLOUD_ENV_CONFIG_FILE"; exit 1; }
[ -n "$AWS_PROFILE_CFG" ] || { error "no AWS profile configured for '$ENV_NAME' in $CLOUD_ENV_CONFIG_FILE - set it to a profile already configured for the AWS CLI (SSO profiles live in ~/.aws/config, static-key profiles in ~/.aws/credentials)"; exit 1; }
require_aws_credentials_file_0600

if [ "$ENV_NAME" = "dev" ]; then
  INGEST_ROBOT_ID_CFG="$(cloud_env_get DEV_INGEST_ROBOT_ID)"
else
  INGEST_ROBOT_ID_CFG="$(cloud_env_get TEST_INGEST_ROBOT_ID)"
fi

VENV_DIR="$NOVHUB_ROOT/.venv"
if [ -d "$VENV_DIR" ]; then
  log "already exists: $VENV_DIR"
else
  python3 -m venv "$VENV_DIR"
  log "created: $VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -q -r "$NOVHUB_ROOT/requirements.txt"

export CLOUD_CHECK_ENV="$ENV_NAME"
export CLOUD_CHECK_DB_LOCAL_PORT="$DB_LOCAL_PORT"
export CLOUD_CHECK_ES_LOCAL_PORT="$ES_LOCAL_PORT"
export CLOUD_CHECK_SECRETS_DIR="$SECRETS_DIR"
export CLOUD_CHECK_VIA_HOSTNAME="$VIA_HOSTNAME"
export CLOUD_CHECK_AWS_REGION="$AWS_REGION_CFG"
export CLOUD_CHECK_AWS_PROFILE="$AWS_PROFILE_CFG"
export CLOUD_CHECK_INGEST_ROBOT_ID="$INGEST_ROBOT_ID_CFG"

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/cloud-check.py"
