#!/usr/bin/env bash
# Stages crash_repro_helper.cpp into celeste, builds it via celeste's own CMake graph
# (crash_repro_helper needs nov_core, which is an OBJECT library with no prebuilt
# artifact to link against from outside -- it has to be compiled in celeste's own
# configure pass), runs the forced-kill repro, then tears everything back down so
# celeste's tracked tree is byte-identical to how it started. See README.md.

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CELESTE_ROOT="${CELESTE_ROOT:-$HOME/dev/celeste}"
BUILD_CONFIG="${BUILD_CONFIG:-RelWithDebInfo}"
# Lowercased: celeste's own build.sh/dev-build-lib always name the dir this way
# regardless of the build type's actual casing (cmake-build-relwithdebinfo, not -RelWithDebInfo).
BUILD_DIR="${CELESTE_ROOT}/back_end/cmake-build-${BUILD_CONFIG,,}"

TARGET_SRC="${CELESTE_ROOT}/back_end/test/integration/crash_repro_helper.cpp"
TARGET_CMAKE="${CELESTE_ROOT}/back_end/test/CMakeLists.txt"

STAGED=false
cleanup() {
    # Only undo what this script itself staged -- never touch the file on an early
    # exit (e.g. the guard check below failing), or it can wipe out unrelated
    # in-progress edits to the same file that have nothing to do with this run.
    if [[ "$STAGED" == true ]]; then
        git -C "$CELESTE_ROOT" checkout -- back_end/test/CMakeLists.txt 2>/dev/null || true
        rm -f "$TARGET_SRC"
    fi
}
trap cleanup EXIT

if [[ -n "$(git -C "$CELESTE_ROOT" status --porcelain -- back_end/test/CMakeLists.txt back_end/test/integration/crash_repro_helper.cpp)" ]]; then
    echo "error: celeste has uncommitted changes to back_end/test/CMakeLists.txt or" >&2
    echo "       back_end/test/integration/crash_repro_helper.cpp -- refusing to stage on" >&2
    echo "       top of in-progress work. Commit/stash first." >&2
    exit 1
fi

if [[ ! -f "${BUILD_DIR}/build/${BUILD_CONFIG}/generators/conan_toolchain.cmake" ]]; then
    echo "error: no configured host build at ${BUILD_DIR}. Run dev-build.sh in this" >&2
    echo "       directory first (needs a real conan toolchain to build against)." >&2
    exit 1
fi

echo "Staging crash_repro_helper into celeste (transient, torn down on exit)..."
cp "${SCRIPT_DIR}/crash_repro_helper.cpp" "$TARGET_SRC"
git -C "$CELESTE_ROOT" apply "${SCRIPT_DIR}/crash_repro_target.patch"
STAGED=true

echo "Building crash_repro_helper via celeste's own nov_core..."
ninja -C "$BUILD_DIR" crash_repro_helper

echo "Running forced-kill repro..."
cd "$BUILD_DIR"
"${SCRIPT_DIR}/crash_repro.sh"
