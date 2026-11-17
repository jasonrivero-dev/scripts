#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: opensearch-resize-heap.sh [heap-size]

HUB-106: bumps the local OpenSearch container's JVM heap (default here was
512m, too small for the 2,000-run/~1.86GB perf dataset) without losing data.

The container has no volume mount - its data lives in the container's own
writable layer - so changing OPENSEARCH_JAVA_OPTS means recreating the
container. This script does it safely: it STOPS the container first (a
graceful shutdown releases OpenSearch's own Lucene lock files cleanly - do
NOT commit a running container, that bakes in stale locks and the new
container will refuse to start), commits the stopped container's filesystem
to a local image, recreates the container from that image with the new heap,
polls for cluster health with a bounded timeout, and verifies every index's
document count is unchanged afterward.

  heap-size   JVM -Xms/-Xmx value (default: \$OPENSEARCH_HEAP or 4g)

No-op (prints "already set") if the container is already running with the
requested heap size. Needs the container up (run-novhub.sh up) first.

The pre-resize snapshot image is kept (not deleted) for manual rollback;
this script does not prune it. Env: OPENSEARCH_RESIZE_TIMEOUT (seconds to
wait for the new container to answer, default 120).
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/steps/opensearch.sh"

TARGET_HEAP="${1:-$OPENSEARCH_HEAP}"
TIMEOUT="${OPENSEARCH_RESIZE_TIMEOUT:-120}"

if ! container_running "$OPENSEARCH_CONTAINER"; then
  error "not running: $OPENSEARCH_CONTAINER - run ./run-novhub.sh up first"
  exit 1
fi

current_opts="$(docker inspect "$OPENSEARCH_CONTAINER" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^OPENSEARCH_JAVA_OPTS=' || true)"
target_opts="OPENSEARCH_JAVA_OPTS=-Xms${TARGET_HEAP} -Xmx${TARGET_HEAP}"

if [ "$current_opts" = "$target_opts" ]; then
  log "already set: $OPENSEARCH_CONTAINER heap is $TARGET_HEAP"
  exit 0
fi

log "current: ${current_opts#OPENSEARCH_JAVA_OPTS=} -> target: -Xms${TARGET_HEAP} -Xmx${TARGET_HEAP}"

pre_counts="$(curl -s "http://127.0.0.1:${OPENSEARCH_PORT}/_cat/indices?h=index,docs.count" | sort)"
log "pre-resize doc counts:"
echo "$pre_counts"

log "stopping $OPENSEARCH_CONTAINER for a clean shutdown (releases its own lock files)..."
docker stop "$OPENSEARCH_CONTAINER" >/dev/null

snapshot_tag="os-local-preheap:$(date -u +%Y%m%dt%H%M%Sz)"
docker commit "$OPENSEARCH_CONTAINER" "$snapshot_tag" >/dev/null
log "created: snapshot image $snapshot_tag (kept for rollback, not auto-pruned)"

docker rm "$OPENSEARCH_CONTAINER" >/dev/null
log "removed: old container (data preserved in $snapshot_tag)"

docker run -d --name "$OPENSEARCH_CONTAINER" -p "127.0.0.1:${OPENSEARCH_PORT}:9200" \
  -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true \
  -e OPENSEARCH_JAVA_OPTS="-Xms${TARGET_HEAP} -Xmx${TARGET_HEAP}" \
  "$snapshot_tag" >/dev/null
log "created: $OPENSEARCH_CONTAINER from $snapshot_tag with heap $TARGET_HEAP"

log "waiting for $OPENSEARCH_CONTAINER to answer on :${OPENSEARCH_PORT} (timeout ${TIMEOUT}s)..."
elapsed=0
until curl -s -o /dev/null "http://127.0.0.1:${OPENSEARCH_PORT}"; do
  if ! container_running "$OPENSEARCH_CONTAINER"; then
    error "FAILED: $OPENSEARCH_CONTAINER exited during startup - see: docker logs $OPENSEARCH_CONTAINER"
    exit 1
  fi
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    error "FAILED: $OPENSEARCH_CONTAINER did not answer within ${TIMEOUT}s - see: docker logs $OPENSEARCH_CONTAINER"
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
  log "...still waiting (${elapsed}s elapsed)"
done
log "answering after ${elapsed}s"

post_counts="$(curl -s "http://127.0.0.1:${OPENSEARCH_PORT}/_cat/indices?h=index,docs.count" | sort)"
if [ "$pre_counts" != "$post_counts" ]; then
  error "doc counts changed after resize - STOP, do not reuse this data without checking $snapshot_tag"
  echo "before:"; echo "$pre_counts"
  echo "after:"; echo "$post_counts"
  exit 1
fi

log "verified: doc counts unchanged, heap is now $TARGET_HEAP"
