PREREQS_REQUIRED_TOOLS=(docker node npm dotnet git-lfs python3 gh)
PREREQS_MAX_MAP_COUNT_MIN=262144

_prereqs_max_map_count() {
  sysctl -n vm.max_map_count
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

  return 0
}
