#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: trace-secret-scan.sh <path-to-trace.json>

HUB-106: scans a Chrome DevTools Performance trace for an Authorization
header, a cookie, a Bearer token, or a JWT - without ever printing the
matched value, only yes/no and where (event name + JSON key path). Run this
BEFORE sharing any trace file anywhere - Chrome's own docs don't say whether
a Performance recording can embed request/response header data.

Exit 0 = nothing found, safe on that front. Exit 1 = found something - do
not share the file until resolved.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

VENV_DIR="$NOVHUB_ROOT/.venv"
if [ -d "$VENV_DIR" ]; then
  log "already exists: $VENV_DIR"
else
  python3 -m venv "$VENV_DIR"
  log "created: $VENV_DIR"
fi

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/trace-secret-scan.py" "$@"
