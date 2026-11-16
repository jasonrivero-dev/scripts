#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<USAGE
Usage: perf-setup.sh

One-time install of Playwright for HUB-106's browser HAR/trace capture, into
novhub-local-stack/.cache/perf-tools. Installs the playwright npm package,
then its Chromium browser via "playwright install --with-deps chromium" -
that step installs OS packages through apt using sudo, and will prompt you
directly for your password. Run with no sudo prefix; it only asks when it
actually needs to.
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PERF_DIR="$SCRIPT_DIR/.cache/perf-tools"
mkdir -p "$PERF_DIR"
cd "$PERF_DIR"

if [ -f package.json ]; then
  log "already exists: $PERF_DIR/package.json"
else
  npm init -y >/dev/null
  log "created: $PERF_DIR/package.json"
fi

if version="$(npx --no-install playwright --version 2>/dev/null)"; then
  log "already installed: $version"
  exit 0
fi

npm install --save-dev playwright || { error "FAILED: npm install playwright"; exit 1; }
log "installing Chromium + its OS packages via apt (sudo required, will prompt)"
npx playwright install --with-deps chromium || { error "FAILED: playwright install --with-deps chromium"; exit 1; }

version="$(npx --no-install playwright --version 2>/dev/null)" || { error "FAILED: playwright did not verify after install"; exit 1; }
log "created: $version"
