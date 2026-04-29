#!/usr/bin/env bash

# gen-coverage.sh: Generic Post-test Analysis Orchestrator
set -e

finish()
{
    echo "------------------------------------------------"
    echo -e "Coverage Analysis Summary:"
    echo -e "  Target:      ${BUILD_TARGET}"
    echo -e "  Project Dir: ${PROJECT_ROOT}"
    echo -e "  Report Dir:  ${REPORT_DIR}"
    echo "------------------------------------------------"
    echo "Analysis Execution Complete."
}

# Register the trap for robustness
trap finish EXIT

# --- 1. Defaults & Parameter Parsing ---
BUILD_TARGET="celeste"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "[${GREEN}log${NC}] $@"; }
error() { echo -e "[${RED}error${NC}] $@"; exit 1; }

usage() {
    echo "Usage: $0 [options]"
    echo "   -t, --target       Specify target folder (celeste, CameraNode, etc.)"
    exit 0
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t|--target)   BUILD_TARGET="$2"; shift ;;
        -h|--help)     usage ;;
        *) usage ;;
    esac
    shift
done

# --- 2. Path & Tooling Robustness ---
SCRIPT_PATH=$(readlink -f "$0")
DEV_ROOT=$(dirname "$(dirname "$SCRIPT_PATH")")
PROJECT_ROOT="${DEV_ROOT}/${BUILD_TARGET}"
REPORT_DIR="${PROJECT_ROOT}/host_coverage_report"

if ! command -v lcov &> /dev/null; then
    error "lcov is not installed. Run: sudo apt install lcov"
fi

if [ ! -d "$PROJECT_ROOT" ]; then
    error "Project directory not found: ${PROJECT_ROOT}"
fi

# --- 3. Surgical Coverage Collection ---
log "Starting Coverage Collection for ${BUILD_TARGET}..."

# Mismatch/Negative bypasses for threads; Source/Gcov for missing headers and noise
lcov --capture --directory "${PROJECT_ROOT}" \
     --output-file "${PROJECT_ROOT}/coverage.info" \
     --ignore-errors mismatch,negative,source,gcov

# --- 4. Filtering & Noise Reduction ---
log "Filtering system and third-party noise..."
# Added .conan2 to patterns to remove external library headers from the report
lcov --remove "${PROJECT_ROOT}/coverage.info" \
     '/usr/*' \
     '*/third/*' \
     '*/test/*' \
     '*/fbs/*' \
     '*/.conan2/*' \
     --output-file "${PROJECT_ROOT}/filtered.info" \
     --ignore-errors unused

# --- 5. Report Generation ---
log "Generating HTML report..."
mkdir -p "${REPORT_DIR}"

# SURGICAL FIX: Added --ignore-errors source to genhtml to bypass missing Catch2 headers
genhtml "${PROJECT_ROOT}/filtered.info" \
        --output-directory "${REPORT_DIR}" \
        --ignore-errors source

log "Surgical Analysis Successful."