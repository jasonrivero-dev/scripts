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

# True if anything is already bound to this exact address:port, OR to a wildcard bind
# (*/0.0.0.0) on that port - a wildcard bind occupies every address, including this one.
# Never reports which process/user owns it - that needs root (lsof -i) and isn't this
# check's business; the caller only needs to know the port is unavailable.
listening_on_address() {
  local addr="$1" port="$2"
  local addr_re="${addr//./\\.}"
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "^(\*|0\.0\.0\.0|${addr_re}):${port}\$"
}

# Returns the pid of a process listening on addr:port, if we have permission to see it (our
# own-user processes, no root needed) - prints nothing if it can't be determined. Used only to
# name a stale leftover process in an error message, never to kill anything.
listener_pid_info() {
  local addr="$1" port="$2"
  local addr_re="${addr//./\\.}"
  ss -ltnp 2>/dev/null | awk -v re="^(\\*|0\\.0\\.0\\.0|${addr_re}):${port}\$" '$4 ~ re' \
    | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

# Refuses with one line if addr:port is already bound to something other than our own tracked
# process. If the pid is visible to us (own-user socket) and its command line references
# ssh_cfg_path, names it explicitly as a leftover ssh process from this env's own config -
# the caller decides whether to stop it by hand; this never kills anything itself.
refuse_if_port_taken() {
  local addr="$1" port="$2" label="$3" ssh_cfg_path="$4"
  local pid
  pid="$(listener_pid_info "$addr" "$port")"
  if [ -n "$pid" ] && ps -p "$pid" -o args= 2>/dev/null | grep -qF "$ssh_cfg_path"; then
    error "${addr}:${port} is already in use by pid $pid - an ssh process matching this env's ssh config that isn't tracked in our pidfile (likely left over from an earlier run) - refusing to start the $label; not killing it, stop it yourself if it's stale and retry"
  elif [ -n "$pid" ]; then
    error "${addr}:${port} is already in use (pid $pid) - refusing to start the $label"
  else
    error "${addr}:${port} is already in use - refusing to start the $label"
  fi
  exit 1
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

# HUB-106 perf-capture/perf-after/perf-rank-robots target config: one git-ignored file per
# target (PERF_CONFIG_FILE, set by ensure_perf_config). "local" auto-creates from the committed
# .example (local defaults only - never committed); any other target name must already have its
# own perf-targets.<target>.env - no hardcoded fallback for a remote target's values.
ensure_perf_config() {
  local target="${1:-local}"
  local file
  if [ "$target" = "local" ]; then
    file="$NOVHUB_ROOT/perf-targets.env"
    if [ -f "$file" ]; then
      log "already exists: $file"
    else
      cp "$NOVHUB_ROOT/perf-targets.env.example" "$file"
      log "created: $file (local defaults - edit to target dev/test)"
    fi
  else
    file="$NOVHUB_ROOT/perf-targets.${target}.env"
    if [ ! -f "$file" ]; then
      error "no config for target '$target' - create $file (KEY=value: PERF_ROBOT_NAME, NOVAPP_URL, NOVAPI_URL - see perf-targets.env.example for the format)"
      exit 1
    fi
    log "already exists: $file"
  fi
  PERF_CONFIG_FILE="$file"
}

perf_config_get() {
  grep -E "^${1}=" "$PERF_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# One naming convention for the per-target secret file, shared by every tool that logs in.
perf_secret_file_for_target() {
  local target="${1:-local}"
  if [ "$target" = "local" ]; then
    echo "$NOVHUB_ROOT/.state/secrets/perf-test-user.secret"
  else
    echo "$NOVHUB_ROOT/.state/secrets/perf-test-user-${target}.secret"
  fi
}

# Tolerant KEY=value reader for the owner's pasted cloud secrets files (novai-<env>/DB.secrets,
# OPENSEARCH.secrets): skips blank lines and any line with no literal '=' at all (a pasted
# "Secret key / Secret value" header row has none), tolerates whitespace around key/value.
# Prints the value only - the caller decides whether to use it or echo a key NAME in an error;
# never echo what this returns.
secrets_kv_get() {
  local file="$1" key="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)\$/\1/p" "$file" 2>/dev/null \
    | head -1 | sed -E 's/[[:space:]]+$//'
}

# One place to turn a secrets-file "host" value into a bare hostname: strips a leading
# scheme (scheme://), any trailing path, and any :port - callers get the port from the
# file's own 'port' key or a protocol default, never from this. Prints the cleaned value,
# or nothing if what's left doesn't look like a plain hostname/IP - callers MUST treat an
# empty result as invalid input and refuse loudly, never fall through to a TCP/SSH check
# built from a mangled string (a check against an invalid host is not a real "not reachable").
normalize_host() {
  local h="$1"
  h="${h#*://}"
  h="${h%%/*}"
  h="${h%%:*}"
  if [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "$h"
  fi
}

# Extracts an explicit :port from a secrets-file host value (after stripping scheme/path,
# same stripping normalize_host does), if the value actually carries one - prints nothing
# otherwise. Callers supply their own default when this is empty; never assume a secrets
# file's separate 'port' key is the same thing; the OpenSearch secrets file's 'port' (9200)
# is a confirmed example of a DIFFERENT value, not the TLS endpoint port (always 443) - see
# the HUB-106 real-run report of a LocalForward built from it timing out.
url_port() {
  local raw="$1"
  local h="${raw#*://}"
  h="${h%%/*}"
  if [[ "$h" == *:* ]]; then
    local p="${h##*:}"
    [[ "$p" =~ ^[0-9]+$ ]] && echo "$p"
  fi
}

require_0600() {
  local file="$1" label="$2"
  [ -f "$file" ] || { error "missing: $file"; exit 1; }
  local mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%OLp' "$file")"
  if [ "$mode" != "600" ]; then
    error "$label $file is mode $mode, not 0600 - refusing"
    exit 1
  fi
}

# Same as require_0600, plus ownership: about to be handed to `sudo`, so a file that isn't
# both 0600 AND owned by the person running this (not root, not anyone else) could mean it was
# tampered with - sudo would then run attacker-controlled config/key material as root.
require_owner_and_0600() {
  local file="$1" label="$2"
  require_0600 "$file" "$label"
  local owner
  owner="$(stat -c '%U' "$file" 2>/dev/null || stat -f '%Su' "$file")"
  if [ "$owner" != "$(whoami)" ]; then
    error "$label $file is owned by '$owner', not you - refusing to sudo with it"
    exit 1
  fi
}

# One format for the /etc/hosts marker, shared by cloud-hosts.sh (which adds/removes it) and
# cloud-ingest.sh (which checks it's present before signing a request to the real hostname) -
# never duplicate the string in two places.
cloud_hosts_marker() {
  echo "# cloud-tunnel-${1} (novhub-local-stack/cloud-hosts.sh - safe to remove by hand)"
}

# Local tunnel ports: one git-ignored file, non-secret (just port numbers), same
# auto-create-from-.example pattern as perf-targets.env.
CLOUD_TUNNEL_PORTS_FILE="$NOVHUB_ROOT/cloud-tunnel-ports.env"

ensure_cloud_tunnel_ports() {
  if [ -f "$CLOUD_TUNNEL_PORTS_FILE" ]; then
    log "already exists: $CLOUD_TUNNEL_PORTS_FILE"
  else
    cp "$NOVHUB_ROOT/cloud-tunnel-ports.env.example" "$CLOUD_TUNNEL_PORTS_FILE"
    log "created: $CLOUD_TUNNEL_PORTS_FILE"
  fi
}

cloud_tunnel_port_get() {
  grep -E "^${1}=" "$CLOUD_TUNNEL_PORTS_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

# AWS region + named credentials profile per environment - non-secret (a region code and a
# profile NAME, never a raw key/secret). Same auto-create pattern as the other cloud-*
# configs. Never ambient: callers export the resolved value as their OWN env var for the one
# subprocess that needs it, never trusting whatever AWS_DEFAULT_REGION/AWS_PROFILE happen to
# already be set to in the shell.
CLOUD_ENV_CONFIG_FILE="$NOVHUB_ROOT/cloud-env.env"

ensure_cloud_env_config() {
  if [ -f "$CLOUD_ENV_CONFIG_FILE" ]; then
    log "already exists: $CLOUD_ENV_CONFIG_FILE"
  else
    cp "$NOVHUB_ROOT/cloud-env.env.example" "$CLOUD_ENV_CONFIG_FILE"
    log "created: $CLOUD_ENV_CONFIG_FILE"
  fi
}

cloud_env_get() {
  grep -E "^${1}=" "$CLOUD_ENV_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

# The named-profile route's actual secret material (static keys) lives only in the owner's
# own ~/.aws/credentials, outside this repo - never ~/.aws/config, which `aws configure`
# itself leaves at 644 by convention (region/profile-name metadata, not a secret) - enforcing
# 0600 there would be a stricter bar than AWS's own tooling applies, so this only checks
# credentials, and only if it exists (an SSO-only profile may have no static keys at all).
require_aws_credentials_file_0600() {
  local f="$HOME/.aws/credentials"
  [ -f "$f" ] || return 0
  require_0600 "$f" "AWS credentials file"
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
