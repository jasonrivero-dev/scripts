NOVHUB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/dev-log-lib
source "$NOVHUB_LIB_DIR/../../lib/dev-log-lib"

NOVHUB_ROOT="$(cd "$NOVHUB_LIB_DIR/.." && pwd)"
STATE_DIR="${NOVHUB_STATE_DIR:-$NOVHUB_ROOT/.state}"
mkdir -p "$STATE_DIR"

# component_dispatch() needs prereqs_check - source it here so every caller of this file gets
# it for free, instead of each one sourcing steps/prereqs.sh separately.
source "$NOVHUB_ROOT/steps/prereqs.sh"

have_container() {
  docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

listening() {
  local port="$1"
  ss -ltnu 2>/dev/null | awk '{print $5}' | grep -qE ":${port}$"
}

is_running() {
  local pidfile="$STATE_DIR/$1.pid"
  [ -f "$pidfile" ] || return 1
  local pid
  pid="$(cat "$pidfile")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

wait_for_port() {
  local name="$1" port="$2"
  until listening "$port"; do
    if ! is_running "$name"; then
      error "FAILED: $name exited before listening on port $port - see $STATE_DIR/$name.log"
      return 1
    fi
    sleep 1
  done
  return 0
}

start_background() {
  local name="$1"
  shift
  local pidfile="$STATE_DIR/$name.pid"
  local logfile="$STATE_DIR/$name.log"
  if is_running "$name"; then
    log "$name already running (pid $(cat "$pidfile"))"
    return 0
  fi
  log "Starting $name in background (log: $logfile)"
  nohup "$@" >"$logfile" 2>&1 &
  echo $! > "$pidfile"
}

stop_background() {
  local name="$1"
  local pidfile="$STATE_DIR/$name.pid"
  if ! is_running "$name"; then
    log "$name not running (no action)"
    rm -f "$pidfile"
    return 0
  fi
  local pid pgid
  pid="$(cat "$pidfile")"
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  log "Stopping $name (pid $pid)"
  kill -- "-${pgid:-$pid}" 2>/dev/null || kill "$pid" 2>/dev/null
  rm -f "$pidfile"
}

read_novdata_db_key() {
  if [ -n "${SWR_DB_KEY:-}" ]; then
    return 0
  fi
  local file="$NOVDATA_REPO/res/initial-roles.sql"
  if [ ! -f "$file" ]; then
    error "NovData's initial-roles.sql not found: $file"
    exit 1
  fi
  SWR_DB_KEY="$(grep -E "CREATE USER novdata WITH PASSWORD" "$file" | sed -E "s/.*PASSWORD '([^']*)'.*/\1/")"
  if [ -z "$SWR_DB_KEY" ]; then
    error "Could not read the novdata role password from $file"
    exit 1
  fi
  export SWR_DB_KEY
}

prompt_secret() {
  local varname="$1"
  local prompt_text="$2"
  if [ -n "${!varname:-}" ]; then
    return 0
  fi
  read -rs -p "$prompt_text: " "$varname"
  echo
  export "$varname"
}

ensure_env_kv() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file"; then
    local current
    current="$(grep -E "^${key}=" "$file" | head -1 | cut -d= -f2-)"
    if [ "$current" = "$value" ]; then
      log "already set: $key=$value"
    else
      sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
      log "corrected: $key=$value (was $current)"
    fi
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
    log "created: $key=$value"
  fi
}

# HUB-106 perf-capture/perf-after target config: one git-ignored file (PERF_CONFIG_FILE),
# auto-created from the committed .example (local defaults only - the owner edits their own
# copy to target dev, never committed). No key here falls back to a hardcoded constant.
PERF_CONFIG_FILE="$NOVHUB_ROOT/perf-targets.env"

ensure_perf_config() {
  if [ -f "$PERF_CONFIG_FILE" ]; then
    log "already exists: $PERF_CONFIG_FILE"
  else
    cp "$NOVHUB_ROOT/perf-targets.env.example" "$PERF_CONFIG_FILE"
    log "created: $PERF_CONFIG_FILE (local defaults - edit to target dev)"
  fi
}

perf_config_get() {
  grep -E "^${1}=" "$PERF_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

read_identity() {
  local conf="/var/opt/novarc/configure"
  if [ ! -f "$conf" ]; then
    error "Robot identity file not found: $conf"
    exit 1
  fi
  local field value
  for field in SWR_ID SWR_NUMBER SWR_CUSTOMER SWR_LOCATION; do
    value="$(grep -E "^${field}=" "$conf" | sed -E "s/^${field}='(.*)'\$/\1/")"
    if [ -z "$value" ]; then
      error "Robot identity file is missing required field: $field ($conf)"
      exit 1
    fi
    printf -v "$field" '%s' "$value"
    export "$field"
  done
  if [ "$SWR_ID" != "NovAI-${SWR_NUMBER}" ]; then
    error "Robot identity file's SWR_ID ($SWR_ID) does not match expected NovAI-$SWR_NUMBER"
    exit 1
  fi
}

component_dispatch() {
  local name="$1" verb="${2:-}"
  if [ -z "$verb" ] || [ "$verb" = "-h" ] || [ "$verb" = "--help" ]; then
    cat <<USAGE
Usage: $name.sh start|stop|status

Standalone entry point for the $name component - identical to what
run-novhub.sh start|stop|status $name calls. Idempotent: an
already-correct state prints "already ..." and changes nothing. If $name
has no stop/status of its own, running one here says so and does nothing.
USAGE
    return 0
  fi
  prereqs_check || return $?
  local fn
  case "$verb" in
    start)  fn="${name}_up" ;;
    stop)   fn="${name}_down" ;;
    status) fn="${name}_check" ;;
    *) error "Unknown action: $verb (expected start|stop|status)"; return 1 ;;
  esac
  if declare -f "$fn" >/dev/null; then
    "$fn"
  else
    log "$name has no persistent state to $verb - nothing to do"
  fi
}
