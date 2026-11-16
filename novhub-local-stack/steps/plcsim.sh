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
    warn "manual: move PLCSIM's REST port (terminal T1)"
    warn "  sudoedit $PLCSIM_CONFIG"
    warn "  under [rest], set bind = \"127.0.0.1:8081\"; leave fins.tcp/fins.udp at 9600"
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

plcsim_down() {
  log "nothing to stop (never started by this script)"
  return 0
}
