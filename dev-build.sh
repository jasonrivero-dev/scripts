#!/usr/bin/env bash

# dev-build.sh: Professional Host-side Orchestrator for Celeste
set -e

finish()
{
    # SURGICAL SUMMARY: Added to provide a clear receipt of the build parameters
    echo "------------------------------------------------"
    echo -e "Surgical Build Summary:"
    echo -e "  Target:   ${BUILD_TARGET}"
    echo -e "  Config:   ${BUILD_CONFIG}"
    echo -e "  Clean:    ${CLEAN_BUILD}"
    echo -e "  Metrics:  ${REBUILD_METRICS}"
    echo -e "  Coverage: ${ENABLE_COV}"
    echo -e "  Run:      ${RUN_AFTER}"
    echo "------------------------------------------------"
    echo "Execution complete."
    echo "Done."
}

# Register the trap to call our function on exit
trap finish EXIT

# --- 1. Defaults & Parameter Parsing ---
BUILD_TARGET="celeste"
BUILD_CONFIG=RelWithDebInfo
REBUILD_METRICS=false
CLEAN_BUILD=false
ENABLE_COV=false
RUN_AFTER=false

# Colors for the UI
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "[${GREEN}log${NC}] $@"; }
warn() { echo -e "[${YELLOW}warn${NC}] $@"; }

usage() {
    echo "Usage: $0 [options]"
    echo "   -cl, --clean       Clean up old build directories & rerun Conan"
    echo "   -m, --metrics      Rebuild and re-install metrics-cpp"
    echo "   -c, --coverage     Enable Code Coverage (atomic updates)"
    echo "   -r, --run          Execute './build.sh dev-run' after build"
    echo "   -t, --target       Specify target folder (celeste, CameraNode, etc.)"
    exit 0
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -cl|--clean)   CLEAN_BUILD=true ;;
        -m|--metrics)  REBUILD_METRICS=true ;;
        -c|--coverage) ENABLE_COV=true ;;
        -r|--run)      RUN_AFTER=true ;;
        -t|--target)   BUILD_TARGET="$2"; shift ;;
        -h|--help)     usage ;;
        *) warn "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# --- 2. Surgical Path Resolution ---
SCRIPT_PATH=$(readlink -f "$0")
DEV_ROOT=$(dirname "$(dirname "$SCRIPT_PATH")")
PROJECT_ROOT="${DEV_ROOT}/${BUILD_TARGET}"

if [ -d "${PROJECT_ROOT}/back_end" ]; then
    BASE_SRC_DIR="${PROJECT_ROOT}/back_end"
else
    BASE_SRC_DIR="${PROJECT_ROOT}"
fi

BUILD_DIR="${BASE_SRC_DIR}/cmake-build-relwithdebinfo"

# --- 3. Build Cleanup & Conan Reconstruction ---
if [ "$CLEAN_BUILD" = true ]; then
    log "Cleaning old build directories in ${PROJECT_ROOT}..."
    rm -rf "${PROJECT_ROOT}/back_end/build"
    rm -rf "${PROJECT_ROOT}/back_end/libs/ffmpeg_recorder/build"
    rm -rf "$BUILD_DIR"
    
    if [ -f "${PROJECT_ROOT}/conanfile.py" ]; then
        log "Reconstructing Conan dependencies (using venv)..."
        if [ -f "$HOME/.venv/bin/activate" ]; then
            source "$HOME/.venv/bin/activate"
            pushd "${PROJECT_ROOT}" > /dev/null
            conan install . --output-folder="${BUILD_DIR}" -s build_type=${BUILD_CONFIG} --build=missing
            popd > /dev/null
        else
            warn "Virtual environment (~/.venv) not found! Skipping Conan install."
        fi
    fi
    log "Cleanup and reconstruction complete."
fi

# --- 4. Metrics Purification ---
if [ "$REBUILD_METRICS" = true ]; then
    log "Purifying metrics-cpp (re-installing to deps/)..."
    pushd "${DEV_ROOT}/celeste/third/metrics-cpp" > /dev/null
    cmake . -DCMAKE_INSTALL_PREFIX="${DEV_ROOT}/celeste/deps/metrics-cpp"
    cmake --build . --target metrics --config $BUILD_CONFIG
    cmake --install .
    popd > /dev/null
fi

# --- 5. CMake Configuration ---
log "Configuring ${BUILD_TARGET} (Coverage: ${ENABLE_COV})..."
cd "$BASE_SRC_DIR"

COV_FLAG="-DENABLE_COVERAGE=OFF"
CXX_FLAGS=""
if [ "$ENABLE_COV" = true ]; then
    COV_FLAG="-DENABLE_COVERAGE=ON"
    CXX_FLAGS="-fprofile-update=atomic"
fi

mkdir -p "$BUILD_DIR"

cmake -G Ninja \
  $COV_FLAG \
  -DCMAKE_CXX_FLAGS="$CXX_FLAGS" \
  -DCMAKE_TOOLCHAIN_FILE="${BUILD_DIR}/build/${BUILD_CONFIG}/generators/conan_toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=$BUILD_CONFIG \
  -DCMAKE_PREFIX_PATH="${DEV_ROOT}/celeste/deps/libtorch" \
  -DCMAKE_CUDA_COMPILER=/usr/bin/nvcc \
  -S . -B "$BUILD_DIR"

# --- 6. Build & Run ---
log "Executing Ninja build for target: ${BUILD_TARGET}..."
ninja -C "$BUILD_DIR"

if [ "$RUN_AFTER" = true ] && [ -f "${PROJECT_ROOT}/build.sh" ]; then
    log "Build successful. Dispatching to dev-run..."
    cd "$PROJECT_ROOT"
    ./build.sh dev-run
fi

log "Surgical Build Complete."