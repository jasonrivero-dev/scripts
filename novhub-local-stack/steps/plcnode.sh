PLCNODE_REPO="${PLCNODE_REPO:-$HOME/dev/plc-node}"
PLCNODE_ETC="/opt/novarc/apps/plc_node/etc"
PLCNODE_CONFIG="$PLCNODE_ETC/plc-node.cfg.toml"
PLCNODE_BIN_DIR="/opt/novarc/apps/plc_node/bin"
PLCNODE_LOG_DIR="/var/log/novarc/plc_node"
PLCNODE_GRPC_PORT=9601

plcnode_check() {
  if ls "$PLCNODE_REPO"/package/plc_node-*.deb >/dev/null 2>&1; then
    log "already built: $(ls "$PLCNODE_REPO"/package/plc_node-*.deb)"
  else
    warn "manual: build the plc-node package (terminal T1, the first 'deps' run is slow)"
    warn "  cd $PLCNODE_REPO"
    warn "  export GH_TOKEN=\$(gh auth token)"
    warn "  ./build_docker.sh deps"
    warn "  ./build_docker.sh generate"
    warn "  ./build_docker.sh build"
    warn "  sudo chown -R \"\$USER\" ."
    warn "  ./deb/package.sh"
    return 2
  fi

  if [ -f "$PLCNODE_CONFIG" ]; then
    log "already installed: /opt/novarc/apps/plc_node"
  else
    warn "manual: install the plc-node package (terminal T1)"
    warn "  cd $PLCNODE_REPO"
    warn "  sudo apt install ./package/plc_node-ubuntu_22.04-x64-*.deb"
    return 2
  fi

  if grep -Eq '^plc-address *= *"127\.0\.0\.1:9600"' "$PLCNODE_CONFIG"; then
    log "already set: plc-address is 127.0.0.1:9600"
  else
    warn "manual: point plc-node at PLCSIM (terminal T1)"
    warn "  sudo sed -i -E 's|^plc-address *=.*|plc-address = \"127.0.0.1:9600\"|' $PLCNODE_CONFIG"
    warn "  then, if plc-node is already running, restart it so it reads the change"
    return 2
  fi

  log "ok: $(grep '^plc-address' "$PLCNODE_CONFIG")"
  log "ok: $(grep '^grpc-bind-address' "$PLCNODE_CONFIG")"

  if [ -d "$PLCNODE_LOG_DIR" ]; then
    log "already exists: $PLCNODE_LOG_DIR"
  else
    warn "manual: create plc-node's log directory (terminal T1)"
    warn "  sudo install -d -o novarc -g novarc $PLCNODE_LOG_DIR"
    return 2
  fi

  if listening "$PLCNODE_GRPC_PORT"; then
    log "already running: something listens on TCP $PLCNODE_GRPC_PORT"
    return 0
  fi

  warn "manual: start plc-node (a terminal of its own, keep it running - start PLCSIM first)"
  warn "  (cd $PLCNODE_BIN_DIR && sudo -u novarc env SWR_TYPE=NOVAI LD_LIBRARY_PATH=$PLCNODE_BIN_DIR/../lib ./plc_node)"
  warn "  expect: \"PLC model: ...\" then \"Server listening on 127.0.0.1:9601\""
  return 2
}

plcnode_up() {
  if ls "$PLCNODE_REPO"/package/plc_node-*.deb >/dev/null 2>&1; then
    log "already built: $(ls "$PLCNODE_REPO"/package/plc_node-*.deb)"
  else
    log "building plc-node package (the deps step can be slow on first run)"
    (
      cd "$PLCNODE_REPO" &&
      export GH_TOKEN="$(gh auth token)" &&
      ./build_docker.sh deps &&
      ./build_docker.sh generate &&
      ./build_docker.sh build &&
      sudo chown -R "$USER" . &&
      ./deb/package.sh
    ) || { error "FAILED: plc-node build"; return 1; }
    log "created: $(ls "$PLCNODE_REPO"/package/plc_node-*.deb)"
  fi

  if [ -f "$PLCNODE_CONFIG" ]; then
    log "already installed: /opt/novarc/apps/plc_node"
  else
    sudo apt install -y "$PLCNODE_REPO"/package/plc_node-ubuntu_22.04-x64-*.deb || { error "FAILED: plc-node install"; return 1; }
    log "created: plc_node installed"
  fi

  if grep -Eq '^plc-address *= *"127\.0\.0\.1:9600"' "$PLCNODE_CONFIG"; then
    log "already set: plc-address is 127.0.0.1:9600"
  else
    sudo sed -i -E 's|^plc-address *=.*|plc-address = "127.0.0.1:9600"|' "$PLCNODE_CONFIG" || { error "FAILED: could not set plc-address"; return 1; }
    log "created: plc-address set to 127.0.0.1:9600"
    # A running instance already loaded the old address and won't reread the file -
    # stop it so the check below starts fresh instead of reusing the stale one.
    if listening "$PLCNODE_GRPC_PORT"; then
      plcnode_down || return 1
    fi
  fi

  if [ -d "$PLCNODE_LOG_DIR" ]; then
    log "already exists: $PLCNODE_LOG_DIR"
  else
    sudo install -d -o novarc -g novarc "$PLCNODE_LOG_DIR" || { error "FAILED: could not create $PLCNODE_LOG_DIR"; return 1; }
    log "created: $PLCNODE_LOG_DIR"
  fi

  if listening "$PLCNODE_GRPC_PORT"; then
    log "already running: something listens on TCP $PLCNODE_GRPC_PORT"
    return 0
  fi

  # Prime the sudo ticket in the foreground - the background job below runs as novarc
  # and can't accept an interactive password prompt once detached.
  sudo -v || { error "FAILED: sudo authentication needed to start plc-node as the novarc user"; return 1; }
  start_background plcnode bash -c "cd \"$PLCNODE_BIN_DIR\" && exec sudo -u novarc env SWR_TYPE=NOVAI LD_LIBRARY_PATH=\"$PLCNODE_BIN_DIR/../lib\" ./plc_node"
  wait_for_port plcnode "$PLCNODE_GRPC_PORT" || return 1
  log "ok: $PLCNODE_GRPC_PORT listening"
  return 0
}

plcnode_down() {
  # The real process runs as novarc, not this script's own user - a plain kill can't
  # signal it, so this uses sudo pkill rather than the generic stop_background path.
  if ! listening "$PLCNODE_GRPC_PORT"; then
    log "already stopped: plc_node"
    rm -f "$STATE_DIR/plcnode.pid"
    return 0
  fi

  sudo pkill -u novarc -f plc_node
  local rc=$?
  if [ "$rc" != "0" ] && [ "$rc" != "1" ]; then
    # pkill itself returns 1 for "no process matched", which is fine here - anything
    # else (e.g. sudo failing outright) is a real failure, not a successful stop.
    error "FAILED: could not stop plc_node (sudo pkill exit $rc)"
    return 1
  fi

  local tries=0
  until [ "$tries" -ge 5 ] || ! listening "$PLCNODE_GRPC_PORT"; do
    tries=$((tries + 1))
    sleep 1
  done
  if listening "$PLCNODE_GRPC_PORT"; then
    error "FAILED: plc_node still listening on $PLCNODE_GRPC_PORT after stop"
    return 1
  fi

  log "stopped: plc_node"
  rm -f "$STATE_DIR/plcnode.pid"
  return 0
}
