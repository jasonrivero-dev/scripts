SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/dev-log-lib
source "$SCRIPT_DIR/../../lib/dev-log-lib"

NOVHUB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${NOVHUB_STATE_DIR:-$NOVHUB_ROOT/.state}"
mkdir -p "$STATE_DIR"

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
  local pid
  pid="$(cat "$pidfile")"
  log "Stopping $name (pid $pid)"
  kill "$pid"
  rm -f "$pidfile"
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
