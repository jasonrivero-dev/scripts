#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: perf-rank-robots.sh --target NAME [--robot-id ID | --robot-exists ID]

HUB-106: read-only - for picking a BEFORE/AFTER robot on a target whose
data we don't control. Logs in with that target's own secret file, lists
its robots (the same GET /api/v2/users/robots?per_page=10000 call NovApp
makes), then asks weld_run for each one (per_page=1, a wide fixed date
range) and reads its "total". Prints a table ranked by total, highest
first. OpenSearch may cap "total" at 10000 - printed as "10000+" when it
does, with a note that the real count may be higher.

Polite to the target: one robot at a time, a short pause between each,
never retries. Never writes anything. Never prints the login or the
token. Read-only and idempotent - safe to re-run any time.

  --target NAME    which config/secret file to use (e.g. test, dev) -
                   required, no default. Resolves the same way
                   perf-capture.sh --target does: perf-targets.<name>.env
                   for NOVAPI_URL (must already exist - create it
                   yourself first, same KEY=value format as
                   perf-targets.env.example), and
                   .state/secrets/perf-test-user-<name>.secret for the
                   login (one line, email:password, chmod 600 by hand) -
                   both overridable with NOVAPI_URL/PERF_SECRET_FILE.
  --robot-id ID     look up just this one robot's total instead of
                   ranking every robot - stdout is exactly one token (a
                   bare number, or "10000+"), nothing else; every log/
                   info/error line this script or the venv setup prints
                   goes to stderr, always, so a caller can read stdout
                   directly without filtering anything out.
  --robot-exists ID  print exactly "yes" or "no" for whether NovApi's own
                   robot list includes this id - same single-token-on-
                   stdout contract as --robot-id.

Env overrides: PERF_RANK_START/PERF_RANK_END (default 2015-01-01 /
2030-12-31 - wide and fixed, printed every run), PERF_RANK_PAUSE_MS
(default 200 - pause between robots).
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TARGET=""
ROBOT_ID_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --robot-id) ROBOT_ID_ARGS=(--robot-id "$2"); shift 2 ;;
    --robot-exists) ROBOT_ID_ARGS=(--robot-exists "$2"); shift 2 ;;
    *) error "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [ -z "$TARGET" ]; then
  error "--target NAME is required (e.g. --target test)" >&2
  exit 1
fi

ensure_perf_config "$TARGET" >&2
[ -z "${NOVAPI_URL:-}" ] && NOVAPI_URL="$(perf_config_get NOVAPI_URL)"
export NOVAPI_URL
[ -n "$NOVAPI_URL" ] || { error "target '$TARGET': $PERF_CONFIG_FILE has no NOVAPI_URL set - refusing" >&2; exit 1; }

[ -n "${PERF_SECRET_FILE:-}" ] || PERF_SECRET_FILE="$(perf_secret_file_for_target "$TARGET")"
export PERF_SECRET_FILE
if [ ! -f "$PERF_SECRET_FILE" ]; then
  error "PERF_SECRET_FILE not found: $PERF_SECRET_FILE - refusing" >&2
  exit 1
fi
secret_mode="$(stat -c '%a' "$PERF_SECRET_FILE" 2>/dev/null || stat -f '%OLp' "$PERF_SECRET_FILE")"
if [ "$secret_mode" != "600" ]; then
  error "PERF_SECRET_FILE $PERF_SECRET_FILE is mode $secret_mode, not 0600 - refusing" >&2
  exit 1
fi

VENV_DIR="$NOVHUB_ROOT/.venv"
# All of this setup output goes to stderr, not stdout - stdout is reserved for
# perf-rank-robots.py's own output (the ranked table normally, or in --robot-id mode exactly
# one token: a number or "10000+", for another script to read without this noise mixed in).
if [ -d "$VENV_DIR" ]; then
  log "already exists: $VENV_DIR" >&2
else
  python3 -m venv "$VENV_DIR"
  log "created: $VENV_DIR" >&2
fi
"$VENV_DIR/bin/pip" install -q -r "$NOVHUB_ROOT/requirements.txt" >&2

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/perf-rank-robots.py" "${ROBOT_ID_ARGS[@]}"
