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
ALL_COMPONENTS=("${ORDERED_STEPS[@]}" sync)

usage() {
  cat <<USAGE
Usage: run-novhub.sh start|stop|status [component]

  start [component]   no component = bring up the whole stack, in order (stops
                       at the first failure or manual-action step; PLCSIM/
                       plc-node build+install+start for real, prompting for
                       sudo when needed). With a component, only that one.
  stop [component]    no component = stop everything this script started
                       (containers stopped, not removed). With a component,
                       only that one.
  status [component]  report current state, change nothing (default with no
                       component). With a component, only that one.

Valid components: ${ALL_COMPONENTS[*]}
('sync' only does real work under start - it is a one-shot job, not a
persistent service, so 'stop sync'/'status sync' just say so.)

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
component="${2:-}"

case "$cmd" in
  start|stop|status)
    if [ -n "$component" ]; then
      case " ${ALL_COMPONENTS[*]} " in
        *" $component "*) ;;
        *)
          error "Unknown component: $component (expected one of: ${ALL_COMPONENTS[*]})"
          exit 1
          ;;
      esac
      component_dispatch "$component" "$cmd"
      exit $?
    fi
    case "$cmd" in
      start) cmd_up ;;
      stop) cmd_down ;;
      status) cmd_status ;;
    esac
    ;;
  -h|--help) usage ;;
  *)
    error "Unknown command: $cmd (expected: start|stop|status)"
    usage
    exit 1
    ;;
esac
