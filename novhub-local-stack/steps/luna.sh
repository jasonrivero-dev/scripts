LUNA_REPO="${LUNA_REPO:-$HOME/dev/scripts/luna}"

luna_check() {
  if pgrep -x luna >/dev/null; then
    log "already running: luna backend"
  else
    warn "manual: start the LUNA backend (terminal T5)"
    warn "  (cd $LUNA_REPO && ./run-luna.sh backend)"
  fi

  warn "manual: confirm the LUNA window is open (terminal T6, desktop session)"
  warn "  if not already open: cd $LUNA_REPO && ./run-luna.sh frontend"
  return 2
}

luna_up() {
  luna_check
}

luna_down() {
  log "nothing to stop (never started by this script)"
  return 0
}
