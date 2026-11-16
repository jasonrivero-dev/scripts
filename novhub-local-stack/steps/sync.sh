NOVSYNC_REPO="${NOVSYNC_REPO:-$HOME/dev/NovSync}"
NOVSYNC_SCRIPT="$NOVSYNC_REPO/NovSync/db_sync_to_rds.py"
NOVSYNC_STATE_DIR="$STATE_DIR/novsync"
SYNC_VENV_DIR="$NOVHUB_ROOT/.venv"
SYNC_REQUIREMENTS="$NOVHUB_ROOT/requirements.txt"
SYNC_LOADER="$NOVHUB_ROOT/loader.py"

sync_up() {
  if [ -d "$SYNC_VENV_DIR" ]; then
    log "already exists: $SYNC_VENV_DIR"
  else
    python3 -m venv "$SYNC_VENV_DIR"
    log "created: $SYNC_VENV_DIR"
  fi
  "$SYNC_VENV_DIR/bin/pip" install -q -r "$SYNC_REQUIREMENTS"
  log "ok: dependencies installed"

  read_novdata_db_key

  NOVDATA_HOST=127.0.0.1 NOVDATA_PORT="$NOVDATA_PG_PORT" NOVDATA_DB=swrdb NOVDATA_USER=novdata \
    SWR_DB_KEY="$SWR_DB_KEY" \
    OPENSEARCH_URL="http://127.0.0.1:${OPENSEARCH_PORT}" OPENSEARCH_INDEX="$OPENSEARCH_INDEX" \
    "$SYNC_VENV_DIR/bin/python" "$SYNC_LOADER"

  if [ -d "$NOVSYNC_STATE_DIR" ]; then
    log "already exists: $NOVSYNC_STATE_DIR"
  else
    # mode 700: NovSync's own db_sync_to_rds.py logs SWR_API_KEY in plaintext here at
    # DEBUG level (confirmed, not fixed upstream) - this only limits local exposure.
    mkdir -m 700 -p "$NOVSYNC_STATE_DIR"
    log "created: $NOVSYNC_STATE_DIR"
  fi

  read_identity
  prompt_secret SECRET_KEY "local API key for the robot (x-api-key NovSync sends)"

  NOVSYNC_DB=True SWR_ID="$SWR_ID" SWR_API_URL="http://127.0.0.1:${NOVAPI_PORT}" \
    SWR_DB_DEST=127.0.0.1 SWR_DB_USER=novdata SWR_DB=swrdb SWR_DB_KEY="$SWR_DB_KEY" \
    SWR_API_KEY="$SECRET_KEY" SWR_REPL_FILE_SRC_PATH="$NOVSYNC_STATE_DIR" \
    "$SYNC_VENV_DIR/bin/python" "$NOVSYNC_SCRIPT" init

  NOVSYNC_DB=True SWR_ID="$SWR_ID" SWR_API_URL="http://127.0.0.1:${NOVAPI_PORT}" \
    SWR_DB_DEST=127.0.0.1 SWR_DB_USER=novdata SWR_DB=swrdb SWR_DB_KEY="$SWR_DB_KEY" \
    SWR_API_KEY="$SECRET_KEY" SWR_REPL_FILE_SRC_PATH="$NOVSYNC_STATE_DIR" \
    "$SYNC_VENV_DIR/bin/python" "$NOVSYNC_SCRIPT"

  log "ok: loader + NovSync sync complete"
  return 0
}
