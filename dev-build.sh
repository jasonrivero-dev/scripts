#!/usr/bin/env bash
set -e

# --- 1. Path Alignment ---
SCRIPT_PATH=$(readlink -f "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_PATH")
DEV_ROOT=$(dirname "$SCRIPTS_DIR")
PROJECT_ROOT="${DEV_ROOT}/celeste"

# Source libraries
source "${SCRIPTS_DIR}/dev-log-lib"
source "${SCRIPTS_DIR}/dev-build-lib"

# Default state
BUILD_CONFIG="RelWithDebInfo"
CLEAN_BUILD=false
REBUILD_METRICS=false
ENABLE_COV=false
RUN_TESTS=false
BUILD_TARGET="celeste"
BUILD_DIR="${PROJECT_ROOT}/back_end/cmake-build-${BUILD_CONFIG}"

# --- 2. Summary Trap ---
finish()
{
    local REPORT_DIR="${PROJECT_ROOT}/reports/host_coverage_report"
    echo "------------------------------------------------"
    log "Execution Summary:"
    echo -e "  Target:      ${BUILD_TARGET}"
    echo -e "  Project Dir: ${PROJECT_ROOT}"
    echo -e "  Report Dir:  ${REPORT_DIR}"
    echo -e "  Build dir:   ${BUILD_DIR}"
    echo "------------------------------------------------"
    log "Analysis Execution Complete."
}
trap finish EXIT

show_help()
{
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h,  --help      Show this help message"
    echo "  -cl, --clean     Clean host build directories"
    echo "  -m,  --metrics   Rebuild metrics library"
    echo "  -c,  --coverage  Enable code coverage (CMake)"
    echo "  -r,  --run       Execute unit tests"
    echo "  -t,  --target    Build config (default: RelWithDebInfo)"
    exit 0
}

# --- 3. Parameter Parsing ---
while [[ "$#" -gt 0 ]];
do
    case $1 in
        -h|--help)      show_help ;;
        -cl|--clean)    CLEAN_BUILD=true ;;
        -m|--metrics)   REBUILD_METRICS=true ;;
        -c|--coverage)  ENABLE_COV=true ;;
        -r|--run)       RUN_TESTS=true ;;
        -t|--target)    BUILD_CONFIG="$2"; shift ;;
        *) warn "Unknown parameter: $1" ;;
    esac
    shift
done


# --- 4. Chained Execution Pipeline ---

# Stage A: Cleaning
if [ "$CLEAN_BUILD" = true ]
then
    clean_host_build
fi

# Stage B: Metrics
if [ "$REBUILD_METRICS" = true ]
then
    rebuild_metrics_host
fi

# Stage C: Compilation
if [ "$CLEAN_BUILD" = false ] || [ "$REBUILD_METRICS" = true ] || [ "$ENABLE_COV" = true ] || [ "$RUN_TESTS" = true ]
then
    if [ "$ENABLE_COV" = true ] || [ "$RUN_TESTS" = true ]
    then
        BUILD_TARGET="celeste tests recorder_tests ffmpeg_recorder"
    fi
    configure_and_build_host
fi

# Stage D: Execution
if [ "$RUN_TESTS" = true ]
then
    run_tests_host
fi

# Stage E: Coverage Reporting
if [ "$ENABLE_COV" = true ] && [ "$RUN_TESTS" = true ]
then
    process_coverage_host
fi

exit 0