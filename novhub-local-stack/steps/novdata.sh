NOVDATA_CONTAINER="novdata-pg"
NOVDATA_PG_PORT=5432
NOVDATA_UDP_PORT=8000
NOVDATA_REPO="${NOVDATA_REPO:-$HOME/dev/NovData}"
NOVDATA_LOG_DIR="$STATE_DIR/novdata-logs"
NOVDATA_REPLICATION_EXPECTED_ROWS=10

_novdata_verify() {
  docker exec "$NOVDATA_CONTAINER" psql -U postgres -d swrdb -c \
    "SELECT id, name, customer, location FROM robot;"

  local total
  total="$(docker exec "$NOVDATA_CONTAINER" psql -U postgres -d swrdb -tAc \
    "SELECT count(*) FROM replication_config;" | tr -d '[:space:]')"
  if [ "$total" = "$NOVDATA_REPLICATION_EXPECTED_ROWS" ]; then
    log "ok: replication_config has $total rows"
  else
    warn "replication_config has $total rows, expected $NOVDATA_REPLICATION_EXPECTED_ROWS"
  fi
}

novdata_check() {
  if ! container_running "$NOVDATA_CONTAINER"; then
    warn "not running: $NOVDATA_CONTAINER"
    return 1
  fi
  log "already running: $NOVDATA_CONTAINER"

  if ! listening "$NOVDATA_UDP_PORT"; then
    warn "not running: NovData (nothing listens on UDP $NOVDATA_UDP_PORT)"
    return 1
  fi
  log "already running: NovData (UDP $NOVDATA_UDP_PORT)"

  _novdata_verify
  return 0
}

novdata_up() {
  if have_container "$NOVDATA_CONTAINER"; then
    docker start "$NOVDATA_CONTAINER" >/dev/null
    log "already exists: $NOVDATA_CONTAINER (started if it was stopped)"
  else
    prompt_secret POSTGRES_PASSWORD "Postgres superuser password for $NOVDATA_CONTAINER (new container)"
    docker run -d --name "$NOVDATA_CONTAINER" -p "127.0.0.1:${NOVDATA_PG_PORT}:5432" \
      -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD -e POSTGRES_DB=swrdb \
      postgres:11-alpine >/dev/null
    log "created: $NOVDATA_CONTAINER"
  fi

  until docker exec "$NOVDATA_CONTAINER" pg_isready -q; do sleep 1; done

  local role_count
  role_count="$(docker exec "$NOVDATA_CONTAINER" psql -U postgres -tAc \
    "SELECT count(*) FROM pg_roles WHERE rolname IN ('novdata','noveye')" | tr -d '[:space:]')"
  if [ "$role_count" = "2" ]; then
    log "already created: roles novdata and noveye"
  else
    log "running initial-roles.sql (a 'database \"swrdb\" already exists' error below is expected and harmless - the container already created it; roles still get created)"
    docker exec -i "$NOVDATA_CONTAINER" psql -U postgres -f - < "$NOVDATA_REPO/res/initial-roles.sql" >/dev/null
    log "created: roles novdata and noveye"
  fi

  read_identity
  mkdir -p "$NOVDATA_LOG_DIR"
  prompt_secret SWR_DB_KEY "novdata role password (see $NOVDATA_REPO/res/initial-roles.sql)"
  export SWR_REPL_FILE_SRC_PATH="$NOVDATA_LOG_DIR"

  start_background novdata bash -c "cd \"$NOVDATA_REPO\" && exec dotnet run --project NovData"

  until listening "$NOVDATA_UDP_PORT"; do sleep 1; done
  log "ok: UDP $NOVDATA_UDP_PORT listening"

  _novdata_verify
  return 0
}

novdata_down() {
  stop_background novdata
  if container_running "$NOVDATA_CONTAINER"; then
    docker stop "$NOVDATA_CONTAINER" >/dev/null
    log "stopped: $NOVDATA_CONTAINER"
  else
    log "already stopped: $NOVDATA_CONTAINER"
  fi
  return 0
}
