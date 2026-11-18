NOVAPP_REPO="${NOVAPP_REPO:-$HOME/dev/novhub}"
NOVAPP_PORT=5173

novapp_check() {
  if listening "$NOVAPP_PORT"; then
    log "already running: NovApp (TCP $NOVAPP_PORT)"
    return 0
  fi
  warn "not running: NovApp (nothing listens on TCP $NOVAPP_PORT)"
  return 1
}

novapp_up() {
  cd "$NOVAPP_REPO"
  if [ -f .env ]; then
    log "already exists: .env (left as it is)"
  else
    cp .env.sample .env
    log "created: .env from .env.sample"
  fi
  ensure_env_kv .env VITE_SERVER_URL "http://localhost:3000"
  ensure_env_kv .env VITE_IS_NOVAI "true"
  ensure_env_kv .env VITE_PRODUCTION "false"
  ensure_env_kv .env VITE_PORT "5173"

  # Never rely on an ambient shell value for the brand flag - same bug class as NovApi's AWS
  # creds leaking in from the shell profile earlier; strip it so only .env's value applies.
  start_background novapp env -u VITE_IS_NOVAI \
    bash -c "cd \"$NOVAPP_REPO\" && npm install && exec npm run dev"

  until listening "$NOVAPP_PORT"; do sleep 1; done
  log "ok: NovApp listening on $NOVAPP_PORT"

  local brand
  brand="$(novapp_brand)"
  log "brand: $brand"
  if [ "$brand" != "NovAI" ]; then
    error "FAILED: NovApp is not running as the NovAI build ($brand) - TAS runs NovAI robots only"
    return 1
  fi
  return 0
}

novapp_brand() {
  local val
  val="$(grep -E '^VITE_IS_NOVAI=' "$NOVAPP_REPO/.env" 2>/dev/null | cut -d= -f2-)"
  case "$val" in
    true) echo "NovAI" ;;
    false) echo "SWR" ;;
    *) echo "unknown (VITE_IS_NOVAI=${val:-unset} in $NOVAPP_REPO/.env)" ;;
  esac
}

novapp_down() {
  stop_background novapp
  return 0
}
