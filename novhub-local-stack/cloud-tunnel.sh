#!/usr/bin/env bash
set -euo pipefail

OPENSEARCH_TUNNEL_PORT=443 # fixed: AWS SigV4 signs the Host header with no port - the real
                            # domain is always 443, so the local end must be too, or every
                            # signature AWS recomputes server-side comes out different (see
                            # the "403 ... signature we calculated does not match" postmortem).

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: cloud-tunnel.sh open|status|close --env dev|test

HUB-106: two read-only SSH local-port-forward tunnels through the cat-dev
bastion to one environment's DB (real port 5432, an ordinary high local
port) and OpenSearch (real port 443, forced to local port 443 too - see
below). Hosts are read at run time from
.state/secrets/novai-<env>/{DB,OPENSEARCH}.secrets. The REMOTE port
forwarded to is an explicit :port in the host value itself if it has
one, else OpenSearch always falls back to 443 (its real HTTPS endpoint -
never that file's separate 'port' key, confirmed to be a different value,
9200, that is not the endpoint) and DB falls back to its file's 'port'
key (confirmed correct there - 5432). "open" prints the resolved
host:port each forward targets (not a secret - already written to
/etc/hosts by cloud-hosts.sh). Idempotent per forward: "open" on an
already-open one prints "already open" and changes nothing; "close" on a
closed one prints "already closed".

  open    start both forwards in the background
  status  "open"/"closed" for each, with pid(s)
  close   stop both

  --env dev|test   which environment's secrets/ports/address to use

WHY OPENSEARCH NEEDS ITS OWN SUDO PROCESS: AWS SigV4 signs the request's
Host header, and the signature only matches if that header carries no
port - a tunnel on a high port (https://host:25432) makes every client
(this tool, cloud-check, the ingester, a local NovApi) sign "host:25432"
while AWS recomputes the signature for "host" alone, so every single
request gets a 403 "signature we calculated does not match". The fix is
binding port 443 locally, which needs root - so ONLY the OpenSearch
forward runs under sudo (one additional small ssh process); the DB
forward stays a normal unprivileged process on its usual high port. The
owner's own ssh config/key are used as-is, never copied or re-owned.
Refuses to sudo at all if that config or the bastion key isn't owned by
you and exactly 0600 - about to run as root, so this isn't optional.
Each env gets its own loopback address (DEV/TEST_OPENSEARCH_LOOPBACK in
cloud-tunnel-ports.env, e.g. 127.0.0.1 / 127.0.0.2) so both envs' port
443 can be open at the same time without colliding. If a local port is
already taken by something we don't track, refuses up front - naming the
pid if it's visible to us and its command line matches this env's own
ssh config (almost always a leftover forward from an earlier run); never
kills it, you stop it yourself and retry. "created" is only printed once
both forwards are confirmed listening under our OWN tracked pid - a port
already held by something else does not count, even briefly, so a dead
forward never gets reported as open. If a forward exits before coming
up, prints its log tail and exits non-zero.

cat-dev's host/user/key come from ~/dev/scripts/bashrc/.functions (the
same place connect_ubuntu/cp_ubuntu/exec_ubuntu read them from) - this
tool only adds port-forwarding, which those don't do.

Note: this bastion is the one explored for dev. Whether it also reaches
test's DB/OpenSearch hosts is unconfirmed - run cloud-bastion-check.sh
--env test first if you haven't already.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ACTION="${1:-}"
shift || true
case "$ACTION" in
  open | status | close) ;;
  *) error "first argument must be open, status, or close"; exit 1 ;;
esac

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

ensure_cloud_tunnel_ports
if [ "$ENV_NAME" = "dev" ]; then
  DB_LOCAL_PORT="$(cloud_tunnel_port_get DEV_DB_LOCAL_PORT)"
  ES_LOOPBACK="$(cloud_tunnel_port_get DEV_OPENSEARCH_LOOPBACK)"
else
  DB_LOCAL_PORT="$(cloud_tunnel_port_get TEST_DB_LOCAL_PORT)"
  ES_LOOPBACK="$(cloud_tunnel_port_get TEST_OPENSEARCH_LOOPBACK)"
fi
[ -n "$DB_LOCAL_PORT" ] || { error "no local DB port configured for '$ENV_NAME' in $CLOUD_TUNNEL_PORTS_FILE"; exit 1; }
[ -n "$ES_LOOPBACK" ] || { error "no OpenSearch loopback address configured for '$ENV_NAME' in $CLOUD_TUNNEL_PORTS_FILE"; exit 1; }

TUNNEL_DB="cloud-tunnel-${ENV_NAME}-db"
TUNNEL_ES="cloud-tunnel-${ENV_NAME}-es"

if [ "$ACTION" = "status" ]; then
  if is_running "$TUNNEL_DB"; then
    log "DB: open (pid $(cat "$STATE_DIR/${TUNNEL_DB}.pid")) - 127.0.0.1:${DB_LOCAL_PORT}"
  else
    log "DB: closed"
  fi
  if is_running "$TUNNEL_ES"; then
    log "OpenSearch: open (pid $(cat "$STATE_DIR/${TUNNEL_ES}.pid")) - ${ES_LOOPBACK}:${OPENSEARCH_TUNNEL_PORT}"
  else
    log "OpenSearch: closed"
  fi
  exit 0
fi

if [ "$ACTION" = "close" ]; then
  if is_running "$TUNNEL_DB"; then stop_background "$TUNNEL_DB"; else log "DB: already closed"; fi
  if is_running "$TUNNEL_ES"; then stop_background "$TUNNEL_ES"; else log "OpenSearch: already closed"; fi
  rm -f "$STATE_DIR/cloud-tunnel-${ENV_NAME}.ssh_config"
  exit 0
fi

# ACTION = open
DB_ALREADY_OPEN=0
ES_ALREADY_OPEN=0
is_running "$TUNNEL_DB" && DB_ALREADY_OPEN=1
is_running "$TUNNEL_ES" && ES_ALREADY_OPEN=1
if [ "$DB_ALREADY_OPEN" -eq 1 ] && [ "$ES_ALREADY_OPEN" -eq 1 ]; then
  log "already open (DB pid $(cat "$STATE_DIR/${TUNNEL_DB}.pid"), OpenSearch pid $(cat "$STATE_DIR/${TUNNEL_ES}.pid"))"
  exit 0
fi

# Fixed path regardless of whether this run (re)writes the file below - lets the checks here
# recognize a leftover ssh process from an earlier run by its -F argument even before we've
# regenerated the file's contents.
SSH_CONFIG="$STATE_DIR/cloud-tunnel-${ENV_NAME}.ssh_config"

if [ "$DB_ALREADY_OPEN" -eq 0 ] && listening "$DB_LOCAL_PORT"; then
  refuse_if_port_taken "127.0.0.1" "$DB_LOCAL_PORT" "DB forward" "$SSH_CONFIG"
fi
if [ "$ES_ALREADY_OPEN" -eq 0 ] && listening_on_address "$ES_LOOPBACK" "$OPENSEARCH_TUNNEL_PORT"; then
  refuse_if_port_taken "$ES_LOOPBACK" "$OPENSEARCH_TUNNEL_PORT" "OpenSearch forward" "$SSH_CONFIG"
fi

BASTION_FUNCTIONS="$HOME/dev/scripts/bashrc/.functions"
[ -f "$BASTION_FUNCTIONS" ] || { error "not found: $BASTION_FUNCTIONS"; exit 1; }
# Only the two cat-dev constants, not the whole personal dotfile - see bashrc/.functions'
# _resolve_server for the single source of truth this mirrors (its cat-dev case also sets
# user=ec2-user, which isn't a standalone constant there, so it's repeated here).
eval "$(grep -E '^(CAT_DEV_BASTION_HOST|CAT_DEV_BASTION_KEY)=' "$BASTION_FUNCTIONS")"
BASTION_USER="ec2-user"
if [ -z "${CAT_DEV_BASTION_HOST:-}" ] || [ -z "${CAT_DEV_BASTION_KEY:-}" ]; then
  error "could not read CAT_DEV_BASTION_HOST/CAT_DEV_BASTION_KEY from $BASTION_FUNCTIONS"
  exit 1
fi
require_0600 "$CAT_DEV_BASTION_KEY" "bastion key"

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
# strips that down to a bare hostname; an invalid result is a parse error, never silently
# used to build a tunnel to nowhere.
DB_HOST="$(normalize_host "$DB_HOST_RAW")"
ES_HOST="$(normalize_host "$ES_HOST_RAW")"
[ -n "$DB_HOST" ] || { error "$DB_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port"; exit 1; }
[ -n "$ES_HOST" ] || { error "$ES_FILE: 'host' value doesn't look like a plain hostname after stripping scheme/path/port"; exit 1; }

# The REMOTE port to forward to: prefer an explicit :port in the host value itself, since
# that's the actual endpoint address; a secrets file's separate 'port' key is NOT guaranteed
# to be that - confirmed for OpenSearch, whose file's 'port' key is 9200 while the managed
# domain's real HTTPS endpoint is 443 (a LocalForward built from the key alone forwarded to
# the wrong port and every OpenSearch read timed out - HUB-106 real-run report). DB has no
# such mismatch (its file's 'port' key - 5432 - matches the real endpoint), so falling back
# to it when the host carries no port is still correct there; OpenSearch falls back to 443
# (its only real option over HTTPS) instead.
DB_PORT_REMOTE="$(url_port "$DB_HOST_RAW")"
[ -n "$DB_PORT_REMOTE" ] || DB_PORT_REMOTE="$(secrets_kv_get "$DB_FILE" port)"
ES_PORT_REMOTE="$(url_port "$ES_HOST_RAW")"
[ -n "$ES_PORT_REMOTE" ] || ES_PORT_REMOTE=443
[[ "$DB_PORT_REMOTE" =~ ^[0-9]+$ ]] || { error "$DB_FILE: could not resolve a remote DB port (no :port in 'host', and 'port' key is missing or not a number)"; exit 1; }
[[ "$ES_PORT_REMOTE" =~ ^[0-9]+$ ]] || { error "internal error: ES_PORT_REMOTE resolved to '$ES_PORT_REMOTE'"; exit 1; }

# Host/port values go in this 0600 SSH config file, never on ssh's own command line - keeps
# them out of `ps` output, unlike passing -L arguments directly. One file, two Host blocks -
# the DB one run as you, the OpenSearch one run as root (via sudo) for its privileged port.
cat > "$SSH_CONFIG" <<EOF
Host $TUNNEL_DB
  HostName $CAT_DEV_BASTION_HOST
  User $BASTION_USER
  IdentityFile $CAT_DEV_BASTION_KEY
  IdentitiesOnly yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  LocalForward 127.0.0.1:${DB_LOCAL_PORT} ${DB_HOST}:${DB_PORT_REMOTE}

Host $TUNNEL_ES
  HostName $CAT_DEV_BASTION_HOST
  User $BASTION_USER
  IdentityFile $CAT_DEV_BASTION_KEY
  IdentitiesOnly yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  LocalForward ${ES_LOOPBACK}:${OPENSEARCH_TUNNEL_PORT} ${ES_HOST}:${ES_PORT_REMOTE}
EOF
chmod 600 "$SSH_CONFIG"

log "DB forward target: ${DB_HOST}:${DB_PORT_REMOTE}"
log "OpenSearch forward target: ${ES_HOST}:${ES_PORT_REMOTE}"

if [ "$DB_ALREADY_OPEN" -eq 1 ]; then
  log "DB: already open (pid $(cat "$STATE_DIR/${TUNNEL_DB}.pid"))"
else
  start_background "$TUNNEL_DB" ssh -F "$SSH_CONFIG" -N "$TUNNEL_DB"
fi

if [ "$ES_ALREADY_OPEN" -eq 1 ]; then
  log "OpenSearch: already open (pid $(cat "$STATE_DIR/${TUNNEL_ES}.pid"))"
else
  require_owner_and_0600 "$SSH_CONFIG" "SSH config"
  require_owner_and_0600 "$CAT_DEV_BASTION_KEY" "bastion key"
  log "OpenSearch forward needs port ${OPENSEARCH_TUNNEL_PORT} - sudo password may be requested now"
  sudo -v || { error "sudo authentication failed - refusing to start the OpenSearch forward"; exit 1; }
  start_background "$TUNNEL_ES" sudo ssh -F "$SSH_CONFIG" -N "$TUNNEL_ES"
fi

# "Up" requires BOTH our own tracked pid still alive AND something listening - port state
# alone isn't enough: a stale leftover process (not ours) can already hold the port while our
# own ssh exited right after on the bind conflict, which is exactly how this printed "created"
# for a forward that had actually died (HUB-106 real-run report, DB pid 3650581 stale).
deadline=$((SECONDS + 15))
while true; do
  db_up=0; es_up=0
  is_running "$TUNNEL_DB" && listening "$DB_LOCAL_PORT" && db_up=1
  is_running "$TUNNEL_ES" && listening_on_address "$ES_LOOPBACK" "$OPENSEARCH_TUNNEL_PORT" && es_up=1

  if [ "$db_up" -eq 1 ] && [ "$es_up" -eq 1 ]; then
    log "created: tunnel open - 127.0.0.1:${DB_LOCAL_PORT} (DB), ${ES_LOOPBACK}:${OPENSEARCH_TUNNEL_PORT} (OpenSearch)"
    exit 0
  fi

  if ! is_running "$TUNNEL_DB"; then
    error "DB forward exited before coming up - log tail ($STATE_DIR/${TUNNEL_DB}.log):"
    tail -n 20 "$STATE_DIR/${TUNNEL_DB}.log" 2>/dev/null | sed 's/^/  /' >&2
    stop_background "$TUNNEL_ES"
    exit 1
  fi
  if ! is_running "$TUNNEL_ES"; then
    error "OpenSearch forward exited before coming up - log tail ($STATE_DIR/${TUNNEL_ES}.log):"
    tail -n 20 "$STATE_DIR/${TUNNEL_ES}.log" 2>/dev/null | sed 's/^/  /' >&2
    stop_background "$TUNNEL_DB"
    exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    error "timed out waiting for both forwards - see $STATE_DIR/${TUNNEL_DB}.log / $STATE_DIR/${TUNNEL_ES}.log"
    stop_background "$TUNNEL_DB"
    stop_background "$TUNNEL_ES"
    exit 1
  fi
  sleep 1
done
