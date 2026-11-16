#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: setup-host.sh

One-time host setup for the three sysctl kernel limits run-novhub.sh needs
(vm.max_map_count, fs.inotify.max_user_watches, fs.inotify.max_user_instances).
Persists them via /etc/sysctl.d/99-novhub-local-stack.conf (survives reboot)
and applies immediately. Run with no sudo prefix - it calls sudo internally,
only if something actually needs changing.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/steps/prereqs.sh"

SYSCTL_CONF="/etc/sysctl.d/99-novhub-local-stack.conf"
DESIRED="vm.max_map_count=$PREREQS_MAX_MAP_COUNT_MIN
fs.inotify.max_user_watches=$PREREQS_MAX_USER_WATCHES_MIN
fs.inotify.max_user_instances=$PREREQS_MAX_USER_INSTANCES_MIN"

conf_ok=false
if [ -f "$SYSCTL_CONF" ] && [ "$(cat "$SYSCTL_CONF" 2>/dev/null)" = "$DESIRED" ]; then
  conf_ok=true
fi

current_map_count="$(_prereqs_max_map_count)"
current_watches="$(_prereqs_max_user_watches)"
current_instances="$(_prereqs_max_user_instances)"

if "$conf_ok" \
  && [ "$current_map_count" -ge "$PREREQS_MAX_MAP_COUNT_MIN" ] \
  && [ "$current_watches" -ge "$PREREQS_MAX_USER_WATCHES_MIN" ] \
  && [ "$current_instances" -ge "$PREREQS_MAX_USER_INSTANCES_MIN" ]; then
  log "already set: $SYSCTL_CONF, all values already active - nothing to do"
  exit 0
fi

if "$conf_ok"; then
  log "already exists: $SYSCTL_CONF"
else
  printf '%s\n' "$DESIRED" | sudo tee "$SYSCTL_CONF" >/dev/null
  log "created: $SYSCTL_CONF"
fi

sudo sysctl -p "$SYSCTL_CONF" >/dev/null
log "ok: applied (vm.max_map_count=$(sysctl -n vm.max_map_count), fs.inotify.max_user_watches=$(sysctl -n fs.inotify.max_user_watches), fs.inotify.max_user_instances=$(sysctl -n fs.inotify.max_user_instances))"
