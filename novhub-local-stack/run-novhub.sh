#!/usr/bin/env bash
set -euo pipefail

# NovData+NOVAPI+NovApp's file watchers can exceed a typical shell's 1024-fd default together.
# Raising the soft limit needs no sudo, up to the hard ceiling.
ulimit -n 65536 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/steps/prereqs.sh"
source "$SCRIPT_DIR/steps/opensearch.sh"
source "$SCRIPT_DIR/steps/novdata.sh"
source "$SCRIPT_DIR/steps/novapi.sh"
source "$SCRIPT_DIR/steps/novapp.sh"
source "$SCRIPT_DIR/steps/plcsim.sh"
source "$SCRIPT_DIR/steps/plcnode.sh"
source "$SCRIPT_DIR/steps/luna.sh"
source "$SCRIPT_DIR/steps/sync.sh"

ORDERED_STEPS=(opensearch novdata novapi novapp plcsim plcnode luna)

usage() {
  cat <<USAGE
Usage: run-novhub.sh [up|status|down|sync]

  up      bring every automatable component up, in order (stops at the first
          failure or manual-action step; PLCSIM/plc-node build+install+start
          for real here, prompting for sudo directly when needed)
  status  report every component's current state, change nothing (default)
  down    stop everything this script started; containers stopped not removed
  sync    load the latest weld into OpenSearch, then run NovSync (standalone)

LUNA's backend/frontend always print manual instructions - this script never
starts them (the frontend needs the real desktop display).
USAGE
}

cmd_up() {
  prereqs_check || return $?
  local name rc
  for name in "${ORDERED_STEPS[@]}"; do
    if "${name}_up"; then
      continue
    else
      rc=$?
      return "$rc"
    fi
  done
  return 0
}

cmd_status() {
  prereqs_check || true
  local name
  for name in "${ORDERED_STEPS[@]}"; do
    "${name}_check" || true
  done
  return 0
}

cmd_down() {
  local i name rc failed=0
  for ((i = ${#ORDERED_STEPS[@]} - 1; i >= 0; i--)); do
    name="${ORDERED_STEPS[$i]}"
    "${name}_down" || { warn "could not stop: $name"; failed=1; }
  done
  return "$failed"
}

cmd="${1:-status}"
case "$cmd" in
  up) cmd_up ;;
  status) cmd_status ;;
  down) cmd_down ;;
  sync) sync_up ;;
  -h|--help) usage ;;
  *)
    error "Unknown command: $cmd (expected: up|status|down|sync)"
    usage
    exit 1
    ;;
esac
