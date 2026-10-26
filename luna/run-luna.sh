#!/usr/bin/env bash
# Runs Luna (backend + frontend) natively on this host for manual QA. No Docker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../lib/dev-log-lib
source "$SCRIPT_DIR/../lib/dev-log-lib"

LUNA_ROOT="${LUNA_ROOT:-$HOME/dev/luna}"
CACHE_DIR="${LUNA_BUILD_CACHE:-$SCRIPT_DIR/.cache}"
BACKEND_DIR="$LUNA_ROOT/luna-backend"
FRONTEND_DIR="$LUNA_ROOT/luna-frontend"
THIRD_DIR="$LUNA_ROOT/third"

FLUTTER_VERSION="3.19.5-stable"
S3_BUCKET="novarc-build-deps"
S3_PREFIX="ubuntu_22.04"
S3_REGION="us-west-2"

LUNA_CONFIG_DIR="/opt/novarc/apps/luna/etc"
LUNA_CONFIG_PATH="$LUNA_CONFIG_DIR/config.toml"
LUNA_LOG_DIR="/tmp/luna-logs"

mkdir -p "$CACHE_DIR"

step_config() {
  if [ -f "$LUNA_CONFIG_PATH" ]; then
    log "Already present: $LUNA_CONFIG_PATH"
    return
  fi
  log "Installing $LUNA_CONFIG_PATH (sudo required)"
  mkdir -p "$LUNA_LOG_DIR"
  sed "s|^loggingDir = .*|loggingDir = \"$LUNA_LOG_DIR/\"|" \
    "$BACKEND_DIR/resources/config.toml" > "$CACHE_DIR/config.toml"
  sudo mkdir -p "$LUNA_CONFIG_DIR"
  sudo cp "$CACHE_DIR/config.toml" "$LUNA_CONFIG_PATH"
  sudo chown "$(id -u):$(id -g)" "$LUNA_CONFIG_PATH"
}

step_binary() {
  cd "$BACKEND_DIR"
  log "Building luna-backend/luna"
  go build -buildvcs=false -o luna .
}

step_frontend_toolchain() {
  local pkgs=(clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libnng-dev)
  local missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "Installing apt packages (sudo required): ${missing[*]}"
    sudo apt-get install -y "${missing[@]}"
  else
    log "apt packages already present"
  fi

  if [ -x "$CACHE_DIR/flutter/bin/flutter" ]; then
    log "Cached: flutter $FLUTTER_VERSION"
  else
    log "Fetching s3://$S3_BUCKET/$S3_PREFIX/flutter_linux_${FLUTTER_VERSION}.tar.xz"
    aws s3api get-object --bucket "$S3_BUCKET" \
      --key "$S3_PREFIX/flutter_linux_${FLUTTER_VERSION}.tar.xz" --region "$S3_REGION" \
      "$CACHE_DIR/flutter.tar.xz" >/dev/null
    tar -C "$CACHE_DIR" -xf "$CACHE_DIR/flutter.tar.xz"
    rm -f "$CACHE_DIR/flutter.tar.xz"
  fi
}

step_frontend_generate() {
  local flatc="$CACHE_DIR/flatc/flatc"
  local protoc="$CACHE_DIR/protoc/bin/protoc"
  if [ ! -x "$flatc" ] || [ ! -x "$protoc" ]; then
    error "flatc/protoc not found under $CACHE_DIR — run build-backend.sh toolchain first"
    exit 1
  fi
  export PATH="$CACHE_DIR/flutter/bin:$PATH"

  log "Generating Dart flatbuffers code"
  "$flatc" --dart -o "$FRONTEND_DIR/lib/noveye" "$THIRD_DIR/odium-fbs/ai_data.fbs"
  "$flatc" --dart -o "$FRONTEND_DIR/lib/noveye" "$THIRD_DIR/odium-fbs/camera-frames.fbs"
  "$flatc" --dart -o "$FRONTEND_DIR/lib/novai" "$THIRD_DIR/odium-fbs/plc_data_v2.fbs"

  log "Copying events-proto/cameranode-proto into luna-frontend/proto"
  cp "$THIRD_DIR"/events-proto/*.proto "$FRONTEND_DIR/proto/"
  cp "$THIRD_DIR"/cameranode-proto/*.proto "$FRONTEND_DIR/proto/"

  export PATH="$HOME/.pub-cache/bin:$PATH"
  if ! command -v protoc-gen-dart >/dev/null; then
    log "Activating dart protoc_plugin"
    dart pub global activate protoc_plugin 21.1.2
  fi
  log "Generating Dart bindings for well-known protobuf types"
  mkdir -p "$FRONTEND_DIR/lib/grpc/google/protobuf"
  "$protoc" --dart_out="$FRONTEND_DIR/lib/grpc" -I"$CACHE_DIR/protoc/include" \
    "$CACHE_DIR"/protoc/include/google/protobuf/*.proto

  cd "$FRONTEND_DIR"
  log "flutter pub get"
  flutter pub get
  log "dart run build_runner build"
  dart run build_runner build
}

step_backend() {
  cd "$BACKEND_DIR"
  log "Starting ./luna (Ctrl+C to stop)"
  ./luna
}

step_frontend() {
  export PATH="$CACHE_DIR/flutter/bin:$PATH"
  cd "$FRONTEND_DIR"
  log "Starting flutter run -d linux"
  flutter run -d linux
}

step_bundle() {
  export PATH="$CACHE_DIR/flutter/bin:$PATH"
  cd "$FRONTEND_DIR"
  log "flutter build linux --release"
  flutter build linux --release
  cd "$LUNA_ROOT"
  log "deb/package.sh"
  ./deb/package.sh "${1:-dev}"
}

cmd="${1:-all}"
case "$cmd" in
  config) step_config ;;
  binary) step_binary ;;
  frontend-toolchain) step_frontend_toolchain ;;
  frontend-generate) step_frontend_generate ;;
  backend) step_backend ;;
  frontend) step_frontend ;;
  bundle) step_bundle "${2:-dev}" ;;
  all)
    step_config
    step_binary
    step_frontend_toolchain
    step_frontend_generate
    log "Setup done. In two separate terminals, run:"
    log "  $0 backend"
    log "  $0 frontend"
    ;;
  *)
    error "Unknown command: $cmd (expected: config|binary|frontend-toolchain|frontend-generate|backend|frontend|bundle|all)"
    exit 1
    ;;
esac
