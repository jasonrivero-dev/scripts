NOVAPI_REPO="${NOVAPI_REPO:-$HOME/dev/NovApi}"
NOVAPI_DB_SERVICE="db_cloud_dev"
NOVAPI_DB_CONTAINER="cloud_db_dev"
NOVAPI_DB_USER="postgres"
NOVAPI_DB_NAME="swrdb_aggr"
NOVAPI_PORT=3000

_novapi_psql() {
  (cd "$NOVAPI_REPO" && docker compose exec -T "$NOVAPI_DB_SERVICE" psql -U "$NOVAPI_DB_USER" -d "$NOVAPI_DB_NAME" -v ON_ERROR_STOP=1 "$@")
}

novapi_check() {
  if ! listening "$NOVAPI_PORT"; then
    warn "not running: NOVAPI (nothing listens on TCP $NOVAPI_PORT)"
    return 1
  fi
  local ping
  ping="$(curl -s "http://127.0.0.1:${NOVAPI_PORT}/api/v1/ping")"
  if [ "$ping" = '{"status":"/pong"}' ]; then
    log "already running: NOVAPI ($ping)"
    return 0
  fi
  warn "NOVAPI listening but ping returned: $ping"
  return 1
}

novapi_up() {
  local was_running=0
  container_running "$NOVAPI_DB_CONTAINER" && was_running=1
  (cd "$NOVAPI_REPO" && docker compose up -d "$NOVAPI_DB_SERVICE" >/dev/null)
  if [ "$was_running" = "1" ]; then
    log "already running: $NOVAPI_DB_CONTAINER"
  else
    log "created: $NOVAPI_DB_CONTAINER"
  fi

  until _novapi_psql -tAc "SELECT 1" >/dev/null 2>&1; do sleep 1; done

  local m first f applied total files
  m="$NOVAPI_REPO/db/migrations"
  first="20191115-110000-initial-centralisation-db.aggr_migration"
  for f in "$first" $(ls "$m" | grep -vx "$first"); do
    applied="$(_novapi_psql -tAc "SELECT 1 FROM migration WHERE name='$f'" 2>/dev/null)" || applied=""
    if [ "$applied" = "1" ]; then
      log "already applied: $f"
      continue
    fi
    log "applying: $f"
    _novapi_psql < "$m/$f" || { error "FAILED: $f"; return 1; }
    _novapi_psql -c "INSERT INTO migration (id, name, robot_id) SELECT nextval('aggr_migration_id_seq'), '$f', -1 WHERE NOT EXISTS (SELECT 1 FROM migration WHERE name='$f');" >/dev/null || { error "FAILED to record: $f"; return 1; }
  done

  total="$(_novapi_psql -tAc 'SELECT count(*) FROM migration' | tr -d '[:space:]')"
  files="$(ls "$m" | wc -l)"
  if [ "$files" = "$total" ]; then
    log "ok: $total/$files migrations recorded"
  else
    warn "migrations recorded ($total) does not match files on disk ($files)"
  fi

  cd "$NOVAPI_REPO"
  if [ -f .env ]; then
    log "already exists: .env (left as it is)"
  else
    cp .env.sample .env
    log "created: .env from .env.sample"
  fi
  ensure_env_kv .env OPENSEARCH_HOST "http://localhost:9200"
  ensure_env_kv .env OPENSEARCH_INDEX "novhub-local"
  ensure_env_kv .env IS_NOVAI "true"
  ensure_env_kv .env DB_USERNAME "postgres"
  ensure_env_kv .env DB_PASSWORD "postgres"
  ensure_env_kv .env DB_PORT "5433"
  ensure_env_kv .env DB_NAME "$NOVAPI_DB_NAME"

  local seeded
  seeded="$(_novapi_psql -tAc "SELECT 1 FROM role_resource rr JOIN users u ON u.id = rr.resource_id WHERE rr.resource_type='users' AND u.email='sim@example.com'" 2>/dev/null)"
  if [ "$seeded" = "1" ]; then
    log "already seeded: robot, key, group, role and user"
  else
    read_identity
    prompt_secret SECRET_KEY "local API key for the robot (x-api-key NovSync sends)"
    prompt_secret LOCAL_PASSWORD "local sign-in password for the NovApp user"

    local pw_hash
    pw_hash="$(printf '%s' "$LOCAL_PASSWORD" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(require('bcryptjs').hashSync(s,10)))")"

    _novapi_psql <<SQL
INSERT INTO robot (id, name, customer, location)
  SELECT $SWR_NUMBER, '$SWR_ID', '$SWR_CUSTOMER', '$SWR_LOCATION'
  WHERE NOT EXISTS (SELECT 1 FROM robot WHERE id = $SWR_NUMBER);
INSERT INTO api_key (robot_id, secret_key, iam_access_key_id, iam_secret_access_key, activated)
  SELECT $SWR_NUMBER, '$SECRET_KEY', 'local-placeholder', 'local-placeholder', true
  WHERE NOT EXISTS (SELECT 1 FROM api_key WHERE robot_id = $SWR_NUMBER);
INSERT INTO robot_tier (robot_id)
  SELECT $SWR_NUMBER WHERE NOT EXISTS (SELECT 1 FROM robot_tier WHERE robot_id = $SWR_NUMBER);
INSERT INTO groups (name)
  SELECT '$SWR_ID' WHERE NOT EXISTS (SELECT 1 FROM groups WHERE name = '$SWR_ID');
INSERT INTO group_resource (group_id, resource_id, resource_type)
  SELECT g.id, $SWR_NUMBER, 'robot' FROM groups g WHERE g.name = '$SWR_ID'
  AND NOT EXISTS (SELECT 1 FROM group_resource gr WHERE gr.group_id = g.id AND gr.resource_id = $SWR_NUMBER AND gr.resource_type = 'robot');
INSERT INTO roles (name)
  SELECT 'admin' WHERE NOT EXISTS (SELECT 1 FROM roles WHERE name = 'admin');
INSERT INTO users (name, email, password, company)
  SELECT 'Sim Admin', 'sim@example.com', '$pw_hash', '$SWR_CUSTOMER'
  WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = 'sim@example.com');
INSERT INTO role_resource (role_id, resource_id, resource_type)
  SELECT r.id, u.id, 'users' FROM roles r, users u WHERE r.name = 'admin' AND u.email = 'sim@example.com'
  AND NOT EXISTS (SELECT 1 FROM role_resource rr WHERE rr.role_id = r.id AND rr.resource_id = u.id AND rr.resource_type = 'users');
SQL
    log "created: robot, key, group, role and user seeded"
  fi

  start_background novapi bash -c "cd \"$NOVAPI_REPO\" && npm install && exec npm run dev"

  until listening "$NOVAPI_PORT"; do sleep 1; done

  local ping
  ping="$(curl -s "http://127.0.0.1:${NOVAPI_PORT}/api/v1/ping")"
  log "ok: $ping"
  return 0
}

novapi_down() {
  stop_background novapi
  if container_running "$NOVAPI_DB_CONTAINER"; then
    (cd "$NOVAPI_REPO" && docker compose stop "$NOVAPI_DB_SERVICE" >/dev/null)
    log "stopped: $NOVAPI_DB_CONTAINER"
  else
    log "already stopped: $NOVAPI_DB_CONTAINER"
  fi
  return 0
}
