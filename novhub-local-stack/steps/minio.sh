NOVAPI_REPO="${NOVAPI_REPO:-$HOME/dev/NovApi}"
MINIO_CONTAINER="minio-local"
MINIO_API_PORT=9000
MINIO_CONSOLE_PORT=9001
# minio/minio is no longer freely pullable (Docker Hub/quay.io both deny); Chainguard mirrors
# real upstream MinIO for free - digest-pinned, verified working (RELEASE.2026-11-16).
MINIO_IMAGE="cgr.dev/chainguard/minio@sha256:68aab277f9748c7c3eb85f178744adba1655c8e33a86987b22d2879ca507c332"
MINIO_ROOT_USER="minioadmin"
MINIO_SECRET_FILE="$STATE_DIR/secrets/minio-root.secret"

minio_check() {
  if ! container_running "$MINIO_CONTAINER"; then
    warn "not running: $MINIO_CONTAINER"
    return 1
  fi
  log "already running: $MINIO_CONTAINER"
  if ! curl -s "http://127.0.0.1:${MINIO_API_PORT}/minio/health/live" >/dev/null; then
    warn "not healthy: $MINIO_CONTAINER (port ${MINIO_API_PORT} not answering)"
    return 1
  fi
  log "ok: $MINIO_CONTAINER healthy on ${MINIO_API_PORT}"
  return 0
}

minio_up() {
  local bucket_name
  bucket_name="$(grep -E '^S3_BUCKET_NAME=' "$NOVAPI_REPO/.env" | cut -d= -f2-)"
  if [ -z "$bucket_name" ]; then
    error "S3_BUCKET_NAME not set in $NOVAPI_REPO/.env"
    return 1
  fi

  mkdir -m 700 -p "$STATE_DIR/secrets"
  if [ -f "$MINIO_SECRET_FILE" ]; then
    log "already exists: $MINIO_SECRET_FILE"
  else
    python3 -c "import secrets; print(secrets.token_urlsafe(16))" > "$MINIO_SECRET_FILE"
    chmod 600 "$MINIO_SECRET_FILE"
    log "created: $MINIO_SECRET_FILE"
  fi
  local root_password
  root_password="$(cat "$MINIO_SECRET_FILE")"

  if have_container "$MINIO_CONTAINER"; then
    docker start "$MINIO_CONTAINER" >/dev/null
    log "already exists: $MINIO_CONTAINER (started if it was stopped)"
  else
    # MINIO_DEFAULT_BUCKETS is a no-op on this image (Chainguard's entrypoint doesn't process
    # it) - the bucket is created explicitly below via the aws CLI instead.
    docker run -d --name "$MINIO_CONTAINER" \
      -p "127.0.0.1:${MINIO_API_PORT}:9000" -p "127.0.0.1:${MINIO_CONSOLE_PORT}:9001" \
      -e MINIO_ROOT_USER="$MINIO_ROOT_USER" -e MINIO_ROOT_PASSWORD="$root_password" \
      "$MINIO_IMAGE" server /data --console-address ":${MINIO_CONSOLE_PORT}" >/dev/null
    log "created: $MINIO_CONTAINER"
  fi

  until curl -s "http://127.0.0.1:${MINIO_API_PORT}/minio/health/live" >/dev/null; do sleep 1; done

  if AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER" AWS_SECRET_ACCESS_KEY="$root_password" AWS_REGION=us-east-1 \
      aws --endpoint-url "http://127.0.0.1:${MINIO_API_PORT}" s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
    log "already exists: bucket $bucket_name"
  else
    AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER" AWS_SECRET_ACCESS_KEY="$root_password" AWS_REGION=us-east-1 \
      aws --endpoint-url "http://127.0.0.1:${MINIO_API_PORT}" s3 mb "s3://$bucket_name" >/dev/null
    log "created: bucket $bucket_name"
  fi

  ensure_env_kv "$NOVAPI_REPO/.env" AWS_ENDPOINT_URL_S3 "http://127.0.0.1:${MINIO_API_PORT}"
  ensure_env_kv "$NOVAPI_REPO/.env" AWS_ACCESS_KEY_ID "$MINIO_ROOT_USER"
  ensure_env_kv "$NOVAPI_REPO/.env" AWS_SECRET_ACCESS_KEY "$root_password"
  return 0
}

minio_down() {
  if container_running "$MINIO_CONTAINER"; then
    docker stop "$MINIO_CONTAINER" >/dev/null
    log "stopped: $MINIO_CONTAINER"
  else
    log "already stopped: $MINIO_CONTAINER"
  fi
  return 0
}
