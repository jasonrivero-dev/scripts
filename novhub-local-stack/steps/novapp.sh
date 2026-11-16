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

  start_background novapp bash -c "cd \"$NOVAPP_REPO\" && npm install && exec npm run dev"

  until listening "$NOVAPP_PORT"; do sleep 1; done
  log "ok: NovApp listening on $NOVAPP_PORT"
  return 0
}

novapp_down() {
  stop_background novapp
  return 0
}
