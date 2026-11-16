PLCSIM_REPO="${PLCSIM_REPO:-$HOME/dev/plc_simulator}"
PLCSIM_CONFIG="/opt/novarc/dev/plc_simulator/etc/plc-simulator.toml"
PLCSIM_FINS_PORT=9600
PLCSIM_REST_PORT=8081

plcsim_check() {
  if ls "$PLCSIM_REPO"/dist/plc_simulator-*.deb >/dev/null 2>&1; then
    log "already built: $(ls "$PLCSIM_REPO"/dist/plc_simulator-*.deb)"
  else
    warn "manual: build the PLCSIM package (terminal T1)"
    warn "  cd $PLCSIM_REPO && git lfs pull && ./build.sh"
    return 2
  fi

  if dpkg -s novarc-plc-simulator >/dev/null 2>&1; then
    log "already installed: novarc-plc-simulator"
  else
    warn "manual: install the PLCSIM package (terminal T1)"
    warn "  cd $PLCSIM_REPO && sudo apt install ./dist/plc_simulator-*.deb"
    return 2
  fi

  if grep -Eq 'bind *= *"127\.0\.0\.1:8081"' "$PLCSIM_CONFIG" 2>/dev/null; then
    log "already set: REST bind is 127.0.0.1:8081"
  else
    warn "manual: move PLCSIM's REST port (terminal T1) - required, the service won't start without this"
    warn "  sudo sed -i 's|^bind = \"127.0.0.1:8080\"|bind = \"127.0.0.1:8081\"|' $PLCSIM_CONFIG"
    warn "  then, if the service is already running:"
    warn "  systemctl is-active --quiet plc-simulator && sudo systemctl restart plc-simulator"
    return 2
  fi

  if systemctl is-active --quiet plc-simulator; then
    log "already running: plc-simulator"
  else
    warn "manual: start the PLCSIM service (terminal T1)"
    warn "  sudo systemctl enable --now plc-simulator"
    return 2
  fi

  if ! listening "$PLCSIM_FINS_PORT"; then
    warn "MISSING: $PLCSIM_FINS_PORT listening"
    return 1
  fi
  log "ok: $PLCSIM_FINS_PORT listening"

  if ! listening "$PLCSIM_REST_PORT"; then
    warn "MISSING: $PLCSIM_REST_PORT listening"
    return 1
  fi
  log "ok: $PLCSIM_REST_PORT listening"

  local status
  status="$(curl -s "http://127.0.0.1:${PLCSIM_REST_PORT}/api/status")"
  log "ok: $status"
  return 0
}

plcsim_up() {
  if ls "$PLCSIM_REPO"/dist/plc_simulator-*.deb >/dev/null 2>&1; then
    log "already built: $(ls "$PLCSIM_REPO"/dist/plc_simulator-*.deb)"
  else
    log "building PLCSIM package (first run also pulls Git LFS data)"
    (cd "$PLCSIM_REPO" && git lfs pull && ./build.sh) || { error "FAILED: PLCSIM build"; return 1; }
    log "created: $(ls "$PLCSIM_REPO"/dist/plc_simulator-*.deb)"
  fi

  if dpkg -s novarc-plc-simulator >/dev/null 2>&1; then
    log "already installed: novarc-plc-simulator"
  else
    sudo apt install -y "$PLCSIM_REPO"/dist/plc_simulator-*.deb || { error "FAILED: PLCSIM install"; return 1; }
    log "created: novarc-plc-simulator installed"
  fi

  if grep -Eq 'bind *= *"127\.0\.0\.1:8081"' "$PLCSIM_CONFIG" 2>/dev/null; then
    log "already set: REST bind is 127.0.0.1:8081"
  else
    sudo sed -i 's|^bind = "127.0.0.1:8080"|bind = "127.0.0.1:8081"|' "$PLCSIM_CONFIG" || { error "FAILED: could not set REST bind"; return 1; }
    log "created: REST bind set to 127.0.0.1:8081"
    if systemctl is-active --quiet plc-simulator; then
      sudo systemctl restart plc-simulator
      log "restarted: plc-simulator (picked up new port)"
    fi
  fi

  if systemctl is-active --quiet plc-simulator; then
    log "already running: plc-simulator"
  else
    sudo systemctl enable --now plc-simulator || { error "FAILED: could not start plc-simulator"; return 1; }
    log "created: plc-simulator enabled and started"
  fi

  local tries=0
  until [ "$tries" -ge 15 ] || { listening "$PLCSIM_FINS_PORT" && listening "$PLCSIM_REST_PORT"; }; do
    tries=$((tries + 1))
    sleep 1
  done
  if ! listening "$PLCSIM_FINS_PORT"; then
    error "FAILED: $PLCSIM_FINS_PORT not listening - check: journalctl -u plc-simulator -n 50"
    return 1
  fi
  log "ok: $PLCSIM_FINS_PORT listening"
  if ! listening "$PLCSIM_REST_PORT"; then
    error "FAILED: $PLCSIM_REST_PORT not listening - check: journalctl -u plc-simulator -n 50"
    return 1
  fi
  log "ok: $PLCSIM_REST_PORT listening"

  local status
  status="$(curl -s "http://127.0.0.1:${PLCSIM_REST_PORT}/api/status")"
  log "ok: $status"
  return 0
}

plcsim_down() {
  if systemctl is-active --quiet plc-simulator; then
    sudo systemctl stop plc-simulator
    log "stopped: plc-simulator"
  else
    log "already stopped: plc-simulator"
  fi
  return 0
}
