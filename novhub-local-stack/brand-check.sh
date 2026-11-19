#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: brand-check.sh

HUB-106: prints which build (NovAI or SWR) NovApi and NovApp are actually
running as right now - reads NovApi's own startup log line and NovApp's
.env, never ambient shell env. TAS runs NovAI robots only, so every
measurement/report should be running NovAI on both sides.

Exit 0 if both are NovAI, 1 otherwise (so other scripts can use this as a
precondition check, e.g. "brand-check.sh || exit 1" before measuring).
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/steps/novapi.sh"
source "$SCRIPT_DIR/steps/novapp.sh"

novapi_b="$(novapi_brand)"
novapp_b="$(novapp_brand)"

log "NovApi brand: $novapi_b"
log "NovApp brand: $novapp_b"

if [ "$novapi_b" = "NovAI" ] && [ "$novapp_b" = "NovAI" ]; then
  exit 0
fi
error "Not running as NovAI on both sides - TAS (the customer this measures) runs NovAI robots only"
exit 1
