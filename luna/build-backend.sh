#!/usr/bin/env bash
# build_docker.sh's image can't authenticate its S3 pulls (BIN_KEY_ID/BIN_ACCESS_KEY aren't
# AWS CLI env vars); this builds the Go backend natively instead, without touching
# build_docker.sh/Makefile/Dockerfile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../lib/dev-log-lib
source "$SCRIPT_DIR/../lib/dev-log-lib"

LUNA_ROOT="${LUNA_ROOT:-$HOME/dev/luna}"
CACHE_DIR="${LUNA_BUILD_CACHE:-$SCRIPT_DIR/.cache}"
BACKEND_DIR="$LUNA_ROOT/luna-backend"
FRONTEND_PROTO_DIR="$LUNA_ROOT/luna-frontend/proto"
THIRD_DIR="$LUNA_ROOT/third"

PROTOC_VERSION="25.1"
PROTOC_GEN_GO_VERSION="v1.35.2"
PROTOC_GEN_GO_GRPC_VERSION="v1.5.1"
FLATC_ZIP="Linux.flatc.binary.g++-10.zip"
S3_BUCKET="novarc-build-deps"
S3_PREFIX="ubuntu_22.04"
S3_REGION="us-west-2"

mkdir -p "$CACHE_DIR"

step_deps() {
  local required=(plc-proto odium-pm-proto odium-fbs events-proto cameranode-proto metrics-go stratus-client-go)
  local missing=()
  for d in "${required[@]}"; do
    [ -d "$THIRD_DIR/$d" ] || missing+=("$d")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "Missing third/* deps (${missing[*]}); fetching via ./build_docker.sh --deps-only"
    (cd "$LUNA_ROOT" && ./build_docker.sh --deps-only)
  else
    log "third/* deps already present"
  fi
}

fetch_s3_object() {
  local key="$1" dest="$2"
  log "Fetching s3://$S3_BUCKET/$key"
  aws s3api get-object --bucket "$S3_BUCKET" --key "$key" --region "$S3_REGION" "$dest" >/dev/null
}

step_toolchain() {
  if [ ! -x "$CACHE_DIR/protoc/bin/protoc" ]; then
    fetch_s3_object "$S3_PREFIX/protoc-linux_${PROTOC_VERSION}.zip" "$CACHE_DIR/protoc.zip"
    mkdir -p "$CACHE_DIR/protoc"
    unzip -oq "$CACHE_DIR/protoc.zip" -d "$CACHE_DIR/protoc"
    rm -f "$CACHE_DIR/protoc.zip"
  else
    log "Cached: protoc $PROTOC_VERSION"
  fi

  if [ ! -x "$CACHE_DIR/flatc/flatc" ]; then
    fetch_s3_object "$S3_PREFIX/$FLATC_ZIP" "$CACHE_DIR/flatc.zip"
    mkdir -p "$CACHE_DIR/flatc"
    unzip -oq "$CACHE_DIR/flatc.zip" -d "$CACHE_DIR/flatc"
    rm -f "$CACHE_DIR/flatc.zip"
  else
    log "Cached: flatc"
  fi

  export GOBIN="$CACHE_DIR/gobin"
  mkdir -p "$GOBIN"
  if [ ! -x "$GOBIN/protoc-gen-go" ]; then
    log "Installing protoc-gen-go $PROTOC_GEN_GO_VERSION"
    go install "google.golang.org/protobuf/cmd/protoc-gen-go@$PROTOC_GEN_GO_VERSION"
  else
    log "Cached: protoc-gen-go $PROTOC_GEN_GO_VERSION"
  fi
  if [ ! -x "$GOBIN/protoc-gen-go-grpc" ]; then
    log "Installing protoc-gen-go-grpc $PROTOC_GEN_GO_GRPC_VERSION"
    go install "google.golang.org/grpc/cmd/protoc-gen-go-grpc@$PROTOC_GEN_GO_GRPC_VERSION"
  else
    log "Cached: protoc-gen-go-grpc $PROTOC_GEN_GO_GRPC_VERSION"
  fi
}

# Mirrors Makefile's generate_flatbuffers/generate_grpc targets, Go output only.
step_generate() {
  local protoc="$CACHE_DIR/protoc/bin/protoc"
  local flatc="$CACHE_DIR/flatc/flatc"
  local gen_go="$CACHE_DIR/gobin/protoc-gen-go"
  local gen_go_grpc="$CACHE_DIR/gobin/protoc-gen-go-grpc"

  log "Generating Go flatbuffers code"
  "$flatc" --go -o "$BACKEND_DIR/services" "$THIRD_DIR/odium-fbs/plc_data_v2.fbs"

  log "Generating gRPC Go code"
  mkdir -p "$BACKEND_DIR/grpc/camera" "$BACKEND_DIR/grpc/plc"

  "$protoc" -I"$FRONTEND_PROTO_DIR" -I"$THIRD_DIR/events-proto" \
    --go-grpc_out="$BACKEND_DIR" --plugin=protoc-gen-go-grpc="$gen_go_grpc" --plugin=protoc-gen-go="$gen_go" \
    "$FRONTEND_PROTO_DIR"/*.proto \
    --go_out="$BACKEND_DIR" "$FRONTEND_PROTO_DIR"/*.proto

  "$protoc" -I"$THIRD_DIR/events-proto" \
    --go-grpc_out="$BACKEND_DIR" --plugin=protoc-gen-go-grpc="$gen_go_grpc" --plugin=protoc-gen-go="$gen_go" \
    "$THIRD_DIR"/events-proto/*.proto \
    --go_out="$BACKEND_DIR" "$THIRD_DIR"/events-proto/*.proto

  "$protoc" -I"$THIRD_DIR/cameranode-proto" \
    --go-grpc_out="$BACKEND_DIR" --plugin=protoc-gen-go-grpc="$gen_go_grpc" --plugin=protoc-gen-go="$gen_go" \
    "$THIRD_DIR"/cameranode-proto/*.proto \
    --go_out="$BACKEND_DIR" "$THIRD_DIR"/cameranode-proto/*.proto

  "$protoc" -I"$THIRD_DIR/plc-proto" \
    --go-grpc_out="$BACKEND_DIR" --plugin=protoc-gen-go-grpc="$gen_go_grpc" --plugin=protoc-gen-go="$gen_go" \
    "$THIRD_DIR"/plc-proto/*.proto \
    --go_out="$BACKEND_DIR" "$THIRD_DIR"/plc-proto/*.proto

  "$protoc" -I"$THIRD_DIR/odium-pm-proto" \
    --go-grpc_out="$BACKEND_DIR" --plugin=protoc-gen-go-grpc="$gen_go_grpc" --plugin=protoc-gen-go="$gen_go" \
    "$THIRD_DIR"/odium-pm-proto/*.proto \
    --go_out="$BACKEND_DIR" "$THIRD_DIR"/odium-pm-proto/*.proto
}

step_build() {
  cd "$BACKEND_DIR"
  log "go build ./..."
  go build ./...
  log "go vet ./..."
  go vet ./...
}

step_test() {
  cd "$BACKEND_DIR"
  log "go test ./..."
  go test ./...
}

cmd="${1:-all}"
case "$cmd" in
  deps) step_deps ;;
  toolchain) step_toolchain ;;
  generate) step_generate ;;
  build) step_build ;;
  test) step_test ;;
  all)
    step_deps
    step_toolchain
    step_generate
    step_build
    step_test
    ;;
  *)
    error "Unknown command: $cmd (expected: deps|toolchain|generate|build|test|all)"
    exit 1
    ;;
esac
