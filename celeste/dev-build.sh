#!/usr/bin/env bash
set -e

# --- 1. Path Alignment ---
SCRIPT_PATH=$(readlink -f "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_PATH")
# This script lives in ~/dev/scripts/celeste/ -- celeste itself is a sibling of
# ~/dev/scripts, not of this celeste/ subdirectory, hence the extra dirname.
DEV_ROOT=$(dirname "$(dirname "$SCRIPTS_DIR")")
PROJECT_ROOT="${DEV_ROOT}/celeste"

source "${SCRIPTS_DIR}/dev-log-lib"
source "${SCRIPTS_DIR}/dev-build-lib"

BUILD_CONFIG="RelWithDebInfo"
CLEAN_BUILD=false
CLEAN_DEPS=false
REBUILD_METRICS=false
ENABLE_COV=false
RUN_TESTS=false
LAUNCH_CELESTE=false
USE_AI_CFG=false
DOCKER_TEST=false
BUILD_TARGET="celeste"
SUCCESS=false # Tracker for the summary
# Lowercased: celeste's own build.sh/CMake always name the dir this way regardless of
# the build type's actual casing (cmake-build-relwithdebinfo, not -RelWithDebInfo) --
# using the mixed-case form here silently builds into a second, unrelated directory.
BUILD_DIR="${PROJECT_ROOT}/back_end/cmake-build-${BUILD_CONFIG,,}"
REPORT_DIR="${PROJECT_ROOT}/reports/host_coverage_report"

# --- 2. Summary Trap ---
finish()
{
    echo "------------------------------------------------"
    log "Execution Summary:"
    if [ "$SUCCESS" = true ]; then log "  STATUS:      SUCCESS"; else error "  STATUS:      FAILED"; fi
    echo -e "  Target:      ${BUILD_TARGET}"
    echo -e "  Project Dir: ${PROJECT_ROOT}"
    echo -e "  Report Dir:  ${REPORT_DIR}"
    echo -e "  Build Dir:   ${BUILD_DIR}"
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
    echo "  -cd, --clean-deps Remove stale in-source CMake artifacts from third/*"
    echo "  -m,  --metrics   Rebuild metrics library"
    echo "  -c,  --coverage  Enable code coverage (CMake)"
    echo "  -r,  --run       Execute unit tests"
    echo "  -l,  --launch    Launch celeste (main config; combine with -a for NovAI)"
    echo "  -a,  --ai        Use the NovAI config with -l"
    echo "  -d,  --docker-test  Clear host build dirs, then run celeste's ./build.sh test"
    echo "                   (host cmake-build-* dirs make Docker's lcov step hard-fail on"
    echo "                   gcov version mismatch -- see build.sh's git history for why)"
    echo "  -t,  --target    Build config (default: RelWithDebInfo)"
    echo "  -mt, --makefile-targets  Explain celeste's repo-root Makefile targets"
    # Surgical Fix: Unregister trap so help doesn't trigger "FAILED" summary
    trap - EXIT
    exit 0
}

# --- 3. Parameter Parsing ---
while [[ "$#" -gt 0 ]];
do
    case $1 in
        -h|--help)      show_help ;;
        -mt|--makefile-targets)
            show_makefile_targets
            trap - EXIT
            exit 0
            ;;
        -cl|--clean)    CLEAN_BUILD=true ;;
        -cd|--clean-deps) CLEAN_DEPS=true ;;
        -m|--metrics)   REBUILD_METRICS=true ;;
        -c|--coverage)  ENABLE_COV=true ;;
        -r|--run)       RUN_TESTS=true ;;
        -l|--launch)    LAUNCH_CELESTE=true ;;
        -a|--ai)        USE_AI_CFG=true ;;
        -d|--docker-test) DOCKER_TEST=true ;;
        -t|--target)    BUILD_CONFIG="$2"; shift ;;
        *) warn "Unknown parameter: $1" ;;
    esac
    shift
done

# --- 4. Chained Execution Pipeline ---

ensure_host_writable

if [ "$CLEAN_BUILD" = true ]; then clean_host_build; fi

if [ "$CLEAN_DEPS" = true ]; then clean_stale_dep_builds; fi

if [ "$REBUILD_METRICS" = true ]; then rebuild_metrics_host; fi

# Stage C: Compilation (Triggered ONLY if metrics, coverage, or run is requested)
if [ "$REBUILD_METRICS" = true ] || [ "$ENABLE_COV" = true ] || [ "$RUN_TESTS" = true ]
then
    if [ "$ENABLE_COV" = true ] || [ "$RUN_TESTS" = true ]
    then
        BUILD_TARGET="celeste tests recorder_tests ffmpeg_recorder"
    fi
    configure_and_build_host
fi

if [ "$RUN_TESTS" = true ]; then run_tests_host; fi

if [ "$ENABLE_COV" = true ] && [ "$RUN_TESTS" = true ]; then process_coverage_host; fi

if [ "$LAUNCH_CELESTE" = true ]; then launch_celeste_host; fi

if [ "$DOCKER_TEST" = true ]; then run_docker_test_host; fi

SUCCESS=true # Set to true only if all stages pass
exit 0