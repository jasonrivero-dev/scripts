NOVAPI_REPO="${NOVAPI_REPO:-$HOME/dev/NovApi}"
NOVAPP_REPO="${NOVAPP_REPO:-$HOME/dev/novhub}"
CLOUD_LOCAL_STATE_DIR="$NOVHUB_ROOT/.state/cloud-local"
CLOUD_LOCAL_NOVAPI_RUNTIME_DIR="$CLOUD_LOCAL_STATE_DIR/novapi-runtime"
CLOUD_LOCAL_NOVAPP_RUNTIME_DIR="$CLOUD_LOCAL_STATE_DIR/novapp-runtime"
CLOUD_LOCAL_NOVAPI_ENV_FILE="$CLOUD_LOCAL_NOVAPI_RUNTIME_DIR/.env"
CLOUD_LOCAL_DB_PORT=3000
CLOUD_LOCAL_APP_PORT=5173
CLOUD_LOCAL_API_PROCESS=cloud-local-novapi
CLOUD_LOCAL_APP_PROCESS=cloud-local-novapp

cloud_local_preflight() {
  local env_name="${1:-}"
  if [ "$env_name" != "dev" ]; then
    error "cloud-local supports only --env dev"
    return 2
  fi

  local db_file="$NOVHUB_ROOT/.state/secrets/novai-dev/DB.secrets"
  local es_file="$NOVHUB_ROOT/.state/secrets/novai-dev/OPENSEARCH.secrets"
  if [ ! -f "$db_file" ] || [ ! -f "$es_file" ]; then
    error "missing dev DB/OpenSearch secret file(s) under $NOVHUB_ROOT/.state/secrets/novai-dev"
    return 1
  fi
  require_0600 "$db_file" "dev DB secrets"
  require_0600 "$es_file" "dev OpenSearch secrets"

  if [ ! -f "$NOVAPI_REPO/package.json" ] ||
     [ ! -f "$NOVAPI_REPO/bin/www" ] ||
     [ ! -f "$NOVAPI_REPO/db/db_init.sql" ]; then
    error "NovApi checkout is missing required runtime files: $NOVAPI_REPO"
    return 1
  fi
  if [ ! -f "$NOVAPP_REPO/package.json" ]; then
    error "NovApp checkout not found: $NOVAPP_REPO"
    return 1
  fi

  local db_local_port es_loopback
  db_local_port="$(cloud_tunnel_port_get DEV_DB_LOCAL_PORT)"
  es_loopback="$(cloud_tunnel_port_get DEV_OPENSEARCH_LOOPBACK)"
  if [[ ! "$db_local_port" =~ ^[0-9]+$ ]] || [ -z "$es_loopback" ]; then
    error "dev tunnel ports are missing or invalid in $CLOUD_TUNNEL_PORTS_FILE"
    return 1
  fi

  local db_host_raw es_host_raw es_host es_index
  db_host_raw="$(secrets_kv_get "$db_file" host)"
  es_host_raw="$(secrets_kv_get "$es_file" host)"
  es_host="$(normalize_host "$es_host_raw")"
  es_index="$(secrets_kv_get "$es_file" index)"
  if [ -z "$db_host_raw" ] || [ -z "$es_host" ] || [ -z "$es_index" ]; then
    error "dev DB/OpenSearch secrets are missing a required host or index setting"
    return 1
  fi

  local marker expected_hosts_line
  marker="$(cloud_hosts_marker dev)"
  expected_hosts_line="${es_loopback} ${es_host} ${marker}"
  if ! grep -Fqx "$expected_hosts_line" /etc/hosts; then
    error "dev OpenSearch hosts mapping is missing; expected the cloud-hosts.sh dev mapping"
    return 1
  fi

  local cloud_profile cloud_region
  cloud_profile="$(cloud_env_get DEV_AWS_PROFILE)"
  cloud_region="$(cloud_env_get DEV_AWS_REGION)"
  if [ "$cloud_profile" != "novai-dev" ] || [ "$cloud_region" != "us-west-2" ]; then
    error "cloud-env.env must configure dev with AWS profile novai-dev and region us-west-2"
    return 1
  fi
  require_aws_credentials_file_0600

  local caller_arn
  if ! caller_arn="$(aws sts get-caller-identity --profile novai-dev --query Arn --output text)"; then
    error "AWS session for profile novai-dev is unavailable; complete AWS SSO login before starting"
    return 1
  fi
  if [[ ! "$caller_arn" =~ ^arn:aws:sts::905418409424:assumed-role/AWSReservedSSO_AdministratorAccess_ ]]; then
    error "AWS profile novai-dev is not using the expected dev administrator role"
    return 1
  fi

  "$NOVHUB_ROOT/cloud-tunnel.sh" status --env dev >/dev/null || {
    error "could not read dev tunnel status"
    return 1
  }
  if ! is_running "cloud-tunnel-dev-db" ||
     ! listening_on_address "127.0.0.1" "$db_local_port"; then
    error "dev Postgres forward is not open on 127.0.0.1:$db_local_port"
    return 1
  fi
  if ! is_running "cloud-tunnel-dev-es" ||
     ! listening_on_address "$es_loopback" 443; then
    error "dev OpenSearch forward is not open on $es_loopback:443"
    return 1
  fi

  if ! "$NOVHUB_ROOT/cloud-check.sh" --env dev --via-hostname; then
    error "dev connectivity check failed; no local application services were started"
    return 1
  fi

  local db_name db_username db_password
  db_name="$(secrets_kv_get "$db_file" name)"
  db_username="$(secrets_kv_get "$db_file" username)"
  db_password="$(secrets_kv_get "$db_file" password)"
  if [ -z "$db_name" ] || [ -z "$db_username" ] || [ -z "$db_password" ]; then
    error "dev DB secrets are missing a required name, username, or password setting"
    return 1
  fi

  CLOUD_LOCAL_DB_NAME="$db_name"
  CLOUD_LOCAL_DB_USERNAME="$db_username"
  CLOUD_LOCAL_DB_PASSWORD="$db_password"
  CLOUD_LOCAL_DB_LOCAL_PORT="$db_local_port"
  CLOUD_LOCAL_ES_HOST="$es_host"
  CLOUD_LOCAL_ES_INDEX="$es_index"
  export CLOUD_LOCAL_DB_NAME CLOUD_LOCAL_DB_USERNAME CLOUD_LOCAL_DB_PASSWORD
  export CLOUD_LOCAL_DB_LOCAL_PORT CLOUD_LOCAL_ES_HOST CLOUD_LOCAL_ES_INDEX

  cloud_local_write_runtime_env || {
    unset CLOUD_LOCAL_DB_NAME CLOUD_LOCAL_DB_USERNAME CLOUD_LOCAL_DB_PASSWORD
    unset CLOUD_LOCAL_DB_LOCAL_PORT CLOUD_LOCAL_ES_HOST CLOUD_LOCAL_ES_INDEX
    return 1
  }
  unset CLOUD_LOCAL_DB_NAME CLOUD_LOCAL_DB_USERNAME CLOUD_LOCAL_DB_PASSWORD
  unset CLOUD_LOCAL_DB_LOCAL_PORT CLOUD_LOCAL_ES_HOST CLOUD_LOCAL_ES_INDEX

  log "dev preflight passed; NovApi runtime configuration is private"
}

cloud_local_write_runtime_env() {
  if [ -L "$CLOUD_LOCAL_STATE_DIR" ] ||
     [ -L "$CLOUD_LOCAL_NOVAPI_RUNTIME_DIR" ] ||
     [ -L "$CLOUD_LOCAL_NOVAPP_RUNTIME_DIR" ]; then
    error "cloud-local runtime directory must not be a symbolic link"
    return 1
  fi

  if ! (
    umask 077
    mkdir -p "$CLOUD_LOCAL_NOVAPI_RUNTIME_DIR" "$CLOUD_LOCAL_NOVAPP_RUNTIME_DIR"
    chmod 700 "$CLOUD_LOCAL_STATE_DIR" "$CLOUD_LOCAL_NOVAPI_RUNTIME_DIR" "$CLOUD_LOCAL_NOVAPP_RUNTIME_DIR"
  ); then
    error "could not create private cloud-local runtime directories"
    return 1
  fi

  local db_init_link="$CLOUD_LOCAL_NOVAPI_RUNTIME_DIR/db_init.sql"
  if [ -e "$db_init_link" ] || [ -L "$db_init_link" ]; then
    if [ ! -L "$db_init_link" ] ||
       [ "$(readlink -f "$db_init_link")" != "$(readlink -f "$NOVAPI_REPO/db/db_init.sql")" ]; then
      error "unexpected file already exists at the private NovApi db_init.sql runtime link"
      return 1
    fi
  else
    ln -s "$NOVAPI_REPO/db/db_init.sql" "$db_init_link"
  fi

  if ! CLOUD_LOCAL_ENV_FILE="$CLOUD_LOCAL_NOVAPI_ENV_FILE" python3 - <<'PY'
import os
import re
import tempfile


def quote_dotenv(value, key):
    if "\n" in value or "\r" in value:
        raise ValueError(f"{key} contains a line break")
    if "#" not in value and value == value.strip():
        return value
    for quote in ("'", "`"):
        if quote not in value:
            return f"{quote}{value}{quote}"
    if '"' not in value and "\\n" not in value and "\\r" not in value:
        return f'"{value}"'
    raise ValueError(f"{key} cannot be represented safely in a dotenv file")


values = {
    "NODE_ENV": "development",
    "PORT": "3000",
    "IS_NOVAI": "true",
    "AWS_PROFILE": "novai-dev",
    "AWS_DEFAULT_REGION": "us-west-2",
    "DB_HOST": "127.0.0.1",
    "DB_PORT": os.environ["CLOUD_LOCAL_DB_LOCAL_PORT"],
    "DB_NAME": os.environ["CLOUD_LOCAL_DB_NAME"],
    "DB_USERNAME": os.environ["CLOUD_LOCAL_DB_USERNAME"],
    "DB_PASSWORD": os.environ["CLOUD_LOCAL_DB_PASSWORD"],
    "OPENSEARCH_HOST": f"https://{os.environ['CLOUD_LOCAL_ES_HOST']}",
    "OPENSEARCH_INDEX": os.environ["CLOUD_LOCAL_ES_INDEX"],
}

path = os.environ["CLOUD_LOCAL_ENV_FILE"]
fd, temporary_path = tempfile.mkstemp(prefix=".novapi-env-", dir=os.path.dirname(path))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as runtime_env:
        for key, value in values.items():
            if not re.fullmatch(r"[A-Z_]+", key):
                raise ValueError("invalid environment variable name")
            runtime_env.write(f"{key}={quote_dotenv(value, key)}\n")
    os.replace(temporary_path, path)
except Exception:
    try:
        os.unlink(temporary_path)
    except FileNotFoundError:
        pass
    raise
PY
  then
    error "could not create private NovApi runtime environment"
    return 1
  fi
  if ! chmod 600 "$CLOUD_LOCAL_NOVAPI_ENV_FILE"; then
    error "could not set private permissions on the NovApi runtime environment"
    return 1
  fi
}

_cloud_local_is_running() (
  STATE_DIR="$CLOUD_LOCAL_STATE_DIR"
  is_running "$1"
)

_cloud_local_start_background() (
  STATE_DIR="$CLOUD_LOCAL_STATE_DIR"
  start_background "$@"
)

_cloud_local_stop_background() (
  STATE_DIR="$CLOUD_LOCAL_STATE_DIR"
  stop_background "$@"
)

_cloud_local_wait_for_port() (
  STATE_DIR="$CLOUD_LOCAL_STATE_DIR"
  wait_for_port "$@"
)

_cloud_local_report_service() {
  local label="$1" process="$2" port="$3"
  if _cloud_local_is_running "$process"; then
    if listening_on_address "127.0.0.1" "$port"; then
      log "$label running (managed, port $port)"
      return 0
    fi
    warn "$label process is running but port $port is not listening"
    return 1
  fi
  if listening_on_address "127.0.0.1" "$port"; then
    warn "port $port is occupied by a process not managed by cloud-local"
    return 1
  fi
  log "$label not running"
}

cloud_local_status() {
  local env_name="${1:-}"
  if [ "$env_name" != "dev" ]; then
    error "cloud-local supports only --env dev"
    return 2
  fi

  local failed=0
  _cloud_local_report_service "NovApi" "$CLOUD_LOCAL_API_PROCESS" "$CLOUD_LOCAL_DB_PORT" || failed=1
  _cloud_local_report_service "NovApp" "$CLOUD_LOCAL_APP_PROCESS" "$CLOUD_LOCAL_APP_PORT" || failed=1
  return "$failed"
}

_cloud_local_wait_for_api() {
  local tries=0 response
  while [ "$tries" -lt 20 ]; do
    if ! _cloud_local_is_running "$CLOUD_LOCAL_API_PROCESS"; then
      error "NovApi exited during startup; see $CLOUD_LOCAL_STATE_DIR/$CLOUD_LOCAL_API_PROCESS.log"
      return 1
    fi
    if response="$(curl -fsS --max-time 3 "http://127.0.0.1:${CLOUD_LOCAL_DB_PORT}/api/v1/auth/ping" 2>/dev/null)" &&
       [ "$response" = '{"status":"/pong"}' ]; then
      log "NovApi ready"
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  error "NovApi did not return its ready response; see $CLOUD_LOCAL_STATE_DIR/$CLOUD_LOCAL_API_PROCESS.log"
  return 1
}

_cloud_local_wait_for_pid_exit() {
  local pid="$1" label="$2" tries=0 process_state
  while [ "$tries" -lt 20 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    process_state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$process_state" in
      Z*) return 0 ;;
    esac
    tries=$((tries + 1))
    sleep 1
  done
  error "timed out waiting for $label to stop"
  return 1
}

_cloud_local_stop_one() {
  local process="$1" label="$2" port="$3" pidfile="$CLOUD_LOCAL_STATE_DIR/$1.pid"
  if _cloud_local_is_running "$process"; then
    local pid
    pid="$(cat "$pidfile")"
    _cloud_local_stop_background "$process" || return 1
    _cloud_local_wait_for_pid_exit "$pid" "$label" || return 1
  else
    _cloud_local_stop_background "$process" || return 1
  fi
  if listening_on_address "127.0.0.1" "$port"; then
    error "$label stopped but port $port remains occupied; leaving runtime configuration in place"
    return 1
  fi
}

_cloud_local_remove_runtime() {
  rm -f -- "$CLOUD_LOCAL_NOVAPI_ENV_FILE" "$CLOUD_LOCAL_NOVAPI_RUNTIME_DIR/db_init.sql"
  rmdir -- "$CLOUD_LOCAL_NOVAPI_RUNTIME_DIR" "$CLOUD_LOCAL_NOVAPP_RUNTIME_DIR" 2>/dev/null || true
}

_cloud_local_rollback_start() {
  local app_started="$1" api_started="$2"
  local failed=0
  if [ "$app_started" -eq 1 ]; then
    _cloud_local_stop_one "$CLOUD_LOCAL_APP_PROCESS" "NovApp" "$CLOUD_LOCAL_APP_PORT" || failed=1
  fi
  if [ "$api_started" -eq 1 ]; then
    if _cloud_local_stop_one "$CLOUD_LOCAL_API_PROCESS" "NovApi" "$CLOUD_LOCAL_DB_PORT"; then
      _cloud_local_remove_runtime
    else
      failed=1
    fi
  fi
  return "$failed"
}

cloud_local_start() {
  local env_name="${1:-}"
  if [ "$env_name" != "dev" ]; then
    error "cloud-local supports only --env dev"
    return 2
  fi

  if _cloud_local_is_running "$CLOUD_LOCAL_API_PROCESS" &&
     listening_on_address "127.0.0.1" "$CLOUD_LOCAL_DB_PORT" &&
     _cloud_local_is_running "$CLOUD_LOCAL_APP_PROCESS" &&
     listening_on_address "127.0.0.1" "$CLOUD_LOCAL_APP_PORT"; then
    log "cloud-local services already running"
    return 0
  fi

  if ! _cloud_local_is_running "$CLOUD_LOCAL_API_PROCESS" &&
     listening_on_address "127.0.0.1" "$CLOUD_LOCAL_DB_PORT"; then
    error "port $CLOUD_LOCAL_DB_PORT is occupied by a process not managed by cloud-local"
    return 1
  fi
  if ! _cloud_local_is_running "$CLOUD_LOCAL_APP_PROCESS" &&
     listening_on_address "127.0.0.1" "$CLOUD_LOCAL_APP_PORT"; then
    error "port $CLOUD_LOCAL_APP_PORT is occupied by a process not managed by cloud-local"
    return 1
  fi

  cloud_local_preflight "$env_name" || return $?

  local api_started=0 app_started=0
  if ! _cloud_local_is_running "$CLOUD_LOCAL_API_PROCESS"; then
    _cloud_local_start_background "$CLOUD_LOCAL_API_PROCESS" env -i \
      "PATH=$PATH" "HOME=$HOME" "TMPDIR=${TMPDIR:-/tmp}" \
      NODE_ENV=development IS_NOVAI=true PORT="$CLOUD_LOCAL_DB_PORT" \
      AWS_PROFILE=novai-dev AWS_DEFAULT_REGION=us-west-2 \
      bash -c 'cd "$1" && exec node "$2"' _ \
      "$CLOUD_LOCAL_NOVAPI_RUNTIME_DIR" "$NOVAPI_REPO/bin/www"
    api_started=1
  fi
  if ! _cloud_local_wait_for_port "$CLOUD_LOCAL_API_PROCESS" "$CLOUD_LOCAL_DB_PORT" ||
     ! _cloud_local_wait_for_api; then
    _cloud_local_rollback_start "$app_started" "$api_started" || true
    return 1
  fi

  if ! _cloud_local_is_running "$CLOUD_LOCAL_APP_PROCESS"; then
    _cloud_local_start_background "$CLOUD_LOCAL_APP_PROCESS" env -i \
      "PATH=$PATH" "HOME=$HOME" "TMPDIR=${TMPDIR:-/tmp}" \
      VITE_SERVER_URL=http://localhost:3000 VITE_IS_NOVAI=true \
      VITE_PRODUCTION=false VITE_PORT="$CLOUD_LOCAL_APP_PORT" \
      bash -c 'cd "$1" && exec npm run dev -- --port "$2" --strictPort --envDir "$3"' _ \
      "$NOVAPP_REPO" "$CLOUD_LOCAL_APP_PORT" "$CLOUD_LOCAL_NOVAPP_RUNTIME_DIR"
    app_started=1
  fi
  if ! _cloud_local_wait_for_port "$CLOUD_LOCAL_APP_PROCESS" "$CLOUD_LOCAL_APP_PORT" ||
     ! _cloud_local_is_running "$CLOUD_LOCAL_APP_PROCESS"; then
    error "NovApp exited during startup; see $CLOUD_LOCAL_STATE_DIR/$CLOUD_LOCAL_APP_PROCESS.log"
    _cloud_local_rollback_start "$app_started" "$api_started" || true
    return 1
  fi

  log "cloud-local ready: NovApp http://localhost:$CLOUD_LOCAL_APP_PORT -> NovApi http://localhost:$CLOUD_LOCAL_DB_PORT"
}

cloud_local_stop() {
  local env_name="${1:-}"
  if [ "$env_name" != "dev" ]; then
    error "cloud-local supports only --env dev"
    return 2
  fi

  local failed=0
  _cloud_local_stop_one "$CLOUD_LOCAL_APP_PROCESS" "NovApp" "$CLOUD_LOCAL_APP_PORT" || failed=1
  if _cloud_local_stop_one "$CLOUD_LOCAL_API_PROCESS" "NovApi" "$CLOUD_LOCAL_DB_PORT"; then
    _cloud_local_remove_runtime
  else
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  log "cloud-local stopped; dev tunnels remain open"
}
