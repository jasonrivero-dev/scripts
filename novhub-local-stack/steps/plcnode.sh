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
    warn "manual: build the plc-node package (terminal T1)"
    warn "  cd $PLCNODE_REPO"
    warn "  export GH_TOKEN=\$(gh auth token)"
    warn "  ./build_docker.sh package"
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

  warn "manual: start plc-node (a terminal of its own, keep it running)"
  warn "  ls $PLCNODE_BIN_DIR"
  warn "  (cd $PLCNODE_BIN_DIR && sudo -u novarc env SWR_TYPE=NOVAI ./plc_node)"
  warn "  if ./plc_node does not exist, use the executable the listing shows"
  return 2
}

plcnode_down() {
  log "nothing to stop (never started by this script)"
  return 0
}
