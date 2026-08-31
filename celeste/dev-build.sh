#!/usr/bin/env bash
#
# dev-build.sh -- host-side build/test/run tooling for celeste (~/dev/celeste).
# Run `./dev-build.sh -hh` for the full story (setup, every flag, gotchas we hit
# building this, typical workflows).
#
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
CUSTOM_CFG=""
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
    echo "  -f,  --cfg <path>  Launch (-l) against an arbitrary config file instead"
    echo "  -d,  --docker-test  Clear host build dirs, then run celeste's ./build.sh test"
    echo "                   (host cmake-build-* dirs make Docker's lcov step hard-fail on"
    echo "                   gcov version mismatch -- see build.sh's git history for why)"
    echo "  -t,  --target    Build config (default: RelWithDebInfo)"
    echo "  -mt, --makefile-targets  Explain celeste's repo-root Makefile targets"
    echo "  -hh, --help-long Full story: setup, every flag, gotchas, typical workflows"
    # Surgical Fix: Unregister trap so help doesn't trigger "FAILED" summary
    trap - EXIT
    exit 0
}

show_help_long()
{
    cat <<'EOF'
dev-build.sh -- host-side build/test/run tooling for celeste (~/dev/celeste)
=============================================================================

WHY THIS LIVES OUTSIDE THE CELESTE REPO

PR #237 (SW-3035, corrupt MP4 captures) originally bundled real, motivated
build.sh/Makefile fixes alongside the recording fix itself. Review feedback
was that changes to shared build tooling "that currently works" for the rest
of the team don't belong bundled into an unrelated bugfix PR, even when
there's a genuine bug underneath -- so celeste's build.sh and
scripts/lib_recorder_dev were reverted to match main exactly, and everything
this script does reproduces those fixes here instead, scoped to this
workflow only. We never edit celeste's build.sh/Makefile from here.

FIRST-TIME SETUP (once, or after a full clean)

celeste's OWN --setup-clion must run first -- it clones third-party deps,
builds metrics-cpp and celeste_infra locally, installs the conan toolchain,
and compiles ffmpeg_recorder. This is a celeste-repo command, not ours:

    cd ~/dev/celeste && ./build.sh --setup-clion

Because build.sh is untouched (matches main), the conan toolchain lands at
the repo-root build/RelWithDebInfo/generators/conan_toolchain.cmake -- NOT
under back_end/. configure_and_build_host() (-r/-c) searches both locations.

EVERY FLAG

  -r          Build celeste + tests + recorder_tests, run them.
  -l  (-a)    Launch celeste (main config; -a for the NovAI config).
  -f <path>   With -l, launch against an arbitrary config file instead of the
              repo's noveye-local-*.cfg (e.g. one set up by celeste-setup.sh at
              /opt/novarc/apps/celeste/etc/noveye.cfg). Never touches celeste's
              own tracked config files.
  -d          Run celeste's own Docker `./build.sh test`, safely (see below).
  -mt         Explain celeste's Makefile targets (it has no self-documentation).
  -cd         Clean stale in-source CMake artifacts under third/* (e.g. a
              `cmake .` run by myceleste.sh leaving CMakeCache.txt beside a
              tracked CMakeLists.txt).
  -cl         Clean the host build dir + ffmpeg_recorder/build.
  -m          Rebuild metrics-cpp for the host.
  -c (with -r) Build+run with coverage instrumentation.
  -t          Build config, default RelWithDebInfo.

GOTCHAS DISCOVERED BUILDING THIS (so you don't have to rediscover them)

1. -d wipes more than it looks like. It clears back_end/cmake-build-*, deps/,
   and repo-root build/ before running Docker's test. All three are exposed
   to a real bug in celeste's Makefile: `copy_deps` does `cp -r`, which NESTS
   instead of overwriting when the destination already exists non-empty --
   so a host build's leftovers silently shadow the container's own build and
   produce baffling undefined-reference link errors. Clearing everything is
   the only reliable fix; clearing just the one stale dependency (e.g.
   deps/metrics-cpp alone) makes it WORSE -- the nest still happens, it just
   relocates the rebuilt copy to the wrong nested path instead of fixing the
   mismatch. Consequence: after -d, you MUST re-run `./build.sh --setup-clion`
   before -r/-l will work again.

2. deps/ and repo-root build/ periodically end up root-owned. Docker runs as
   root and bind-mounts the repo, so anything it writes there lands
   root-owned on the host. ensure_host_writable() runs before every
   build-affecting command and only prompts for sudo when something actually
   needs it -- checked recursively, since Docker can leave a directory itself
   user-owned while individual files deep inside (e.g.
   build/.cmake/api/v1/reply/*.json) are root-owned.

3. celeste_extensions/plugins/libffmpeg_recorder.so: celeste's own
   infra_dev_links (in build.sh) points this at repo-root build/ -- Docker's
   ABI, different OpenCV/spdlog versions than the host. link_host_plugins()
   manages our own copy of this symlink against the actual host build, so
   -r/-l don't silently pick up the wrong-ABI plugin and fail with a dlopen
   error mid-test.

TYPICAL WORKFLOWS

# Confirm a change builds and passes tests
~/dev/scripts/celeste/dev-build.sh -r

# See it actually run (main config; add -a for NovAI)
~/dev/scripts/celeste/dev-build.sh -l

# Full CI-equivalent Docker suite -- -d wipes the host build dir/deps/build, so
# --setup-clion has to regenerate the conan toolchain before -r works again
~/dev/scripts/celeste/dev-build.sh -d
cd ~/dev/celeste && ./build.sh --setup-clion
~/dev/scripts/celeste/dev-build.sh -r

# Verify SW-3035 crash-resilience on real GPU (forced kill -9 mid-recording)
~/dev/scripts/FFMpegCrash/run.sh

# A third-party checkout's stray `cmake .` broke the Docker build
~/dev/scripts/celeste/dev-build.sh -cd

# New to this repo and the Makefile is confusing
~/dev/scripts/celeste/dev-build.sh -mt

# Want a known-working local config: real AI models, sample video, no PLC
# hang -- Paolo's setup, adapted to this machine. Needs a built celeste binary
# first (skip the first two lines if you already have one); celeste-setup.sh
# itself is one-time -- re-run it after editing ~/dev/celeste-files/noveye.cfg
# to redeploy that edit to /opt/novarc/apps/celeste/etc/noveye.cfg.
cd ~/dev/celeste && ./build.sh --setup-clion
~/dev/scripts/celeste/dev-build.sh -r
~/dev/scripts/celeste/celeste-setup.sh
~/dev/scripts/celeste/dev-build.sh -l -f /opt/novarc/apps/celeste/etc/noveye.cfg
EOF
    trap - EXIT
    exit 0
}

# --- 3. Parameter Parsing ---
while [[ "$#" -gt 0 ]];
do
    case $1 in
        -h|--help)      show_help ;;
        -hh|--help-long) show_help_long ;;
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
        -f|--cfg)       CUSTOM_CFG="$2"; shift ;;
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