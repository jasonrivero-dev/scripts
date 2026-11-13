OPENSEARCH_CONTAINER="os-local"
OPENSEARCH_PORT=9200
OPENSEARCH_INDEX="novhub-local"
OPENSEARCH_IMAGE="opensearchproject/opensearch:2.19.0"

opensearch_check() {
  if container_running "$OPENSEARCH_CONTAINER"; then
    log "already running: $OPENSEARCH_CONTAINER"
  else
    warn "not running: $OPENSEARCH_CONTAINER"
    return 1
  fi

  local index_status
  index_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${OPENSEARCH_PORT}/${OPENSEARCH_INDEX}")"
  if [ "$index_status" = "200" ]; then
    log "already exists: index $OPENSEARCH_INDEX"
    return 0
  else
    warn "missing: index $OPENSEARCH_INDEX"
    return 1
  fi
}

opensearch_up() {
  if have_container "$OPENSEARCH_CONTAINER"; then
    docker start "$OPENSEARCH_CONTAINER" >/dev/null
    log "already exists: $OPENSEARCH_CONTAINER (started if it was stopped)"
  else
    docker run -d --name "$OPENSEARCH_CONTAINER" -p "127.0.0.1:${OPENSEARCH_PORT}:9200" \
      -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true \
      -e OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m" \
      "$OPENSEARCH_IMAGE" >/dev/null
    log "created: $OPENSEARCH_CONTAINER"
  fi

  until curl -s "http://127.0.0.1:${OPENSEARCH_PORT}" >/dev/null; do sleep 2; done

  local index_status
  index_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${OPENSEARCH_PORT}/${OPENSEARCH_INDEX}")"
  if [ "$index_status" = "200" ]; then
    log "already exists: index $OPENSEARCH_INDEX"
  else
    curl -s -X PUT "http://127.0.0.1:${OPENSEARCH_PORT}/${OPENSEARCH_INDEX}" \
      -H 'Content-Type: application/json' \
      -d "@$NOVHUB_ROOT/opensearch-mapping.json" >/dev/null
    log "created: index $OPENSEARCH_INDEX"
  fi

  return 0
}

opensearch_down() {
  if container_running "$OPENSEARCH_CONTAINER"; then
    docker stop "$OPENSEARCH_CONTAINER" >/dev/null
    log "stopped: $OPENSEARCH_CONTAINER"
  else
    log "already stopped: $OPENSEARCH_CONTAINER"
  fi
  return 0
}
