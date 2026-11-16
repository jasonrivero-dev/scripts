PREREQS_REQUIRED_TOOLS=(docker node npm dotnet git-lfs python3 gh)
PREREQS_MAX_MAP_COUNT_MIN=262144
PREREQS_MAX_USER_WATCHES_MIN=524288

_prereqs_max_map_count() {
  sysctl -n vm.max_map_count
}

_prereqs_max_user_watches() {
  sysctl -n fs.inotify.max_user_watches
}

prereqs_check() {
  local missing=()
  local tool
  for tool in "${PREREQS_REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  docker compose version >/dev/null 2>&1 || missing+=("docker compose")

  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing required tool(s): ${missing[*]}"
    error "Install the missing tool(s) above, then rerun."
    return 2
  fi
  log "All required tools present: ${PREREQS_REQUIRED_TOOLS[*]}, docker compose"

  local current
  current="$(_prereqs_max_map_count)"
  if [ "$current" -lt "$PREREQS_MAX_MAP_COUNT_MIN" ]; then
    error "vm.max_map_count is $current, OpenSearch needs at least $PREREQS_MAX_MAP_COUNT_MIN"
    error "Run: sudo sysctl -w vm.max_map_count=$PREREQS_MAX_MAP_COUNT_MIN"
    return 2
  fi
  log "vm.max_map_count already set ($current >= $PREREQS_MAX_MAP_COUNT_MIN)"

  local watches
  watches="$(_prereqs_max_user_watches)"
  if [ "$watches" -lt "$PREREQS_MAX_USER_WATCHES_MIN" ]; then
    error "fs.inotify.max_user_watches is $watches, NOVAPI+NovApp's file watchers need headroom above $PREREQS_MAX_USER_WATCHES_MIN"
    error "Run: sudo sysctl -w fs.inotify.max_user_watches=$PREREQS_MAX_USER_WATCHES_MIN"
    return 2
  fi
  log "fs.inotify.max_user_watches already set ($watches >= $PREREQS_MAX_USER_WATCHES_MIN)"

  return 0
}
