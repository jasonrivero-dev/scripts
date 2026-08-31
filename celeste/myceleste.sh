#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Navigate to the project root
cd ~/dev/celeste
BUILD_CONFIG=RelWithDebInfo
BASE_DIRECTORY=$PWD

# Clean up old build directories
rm -rf ./back_end/build ./back_end/libs/ffmpeg_recorder/build

# This will actually cleanup metrics which always gives trouble after executing docker. this needs to be an option (parameter build-metrics or somethiong)
echo "Building dependencies..."
    pushd third/metrics-cpp > /dev/null
    cmake . -DCMAKE_INSTALL_PREFIX="${BASE_DIRECTORY}/deps/metrics-cpp"
    cmake --build . --target metrics --config $BUILD_CONFIG
    cmake --install .
    popd > /dev/null


# Move to back_end and configure the project with CMake
 # do we need a enable coverage on off in the parameters?
cd back_end
cmake -G Ninja \
  -DENABLE_COVERAGE=ON \
  -DCMAKE_CXX_FLAGS="-fprofile-update=atomic" \
  -DCMAKE_TOOLCHAIN_FILE=~/dev/celeste/back_end/cmake-build-relwithdebinfo/build/RelWithDebInfo/generators/conan_toolchain.cmake \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_PREFIX_PATH=~/dev/celeste/deps/libtorch \
  -DCMAKE_LIBRARY_PATH=~/dev/celeste/build \
  -DCMAKE_CUDA_COMPILER=/usr/bin/nvcc \
  -S . -B cmake-build-relwithdebinfo
  
# Build the specific target
cd cmake-build-relwithdebinfo
ninja celeste
# we definitely need an on of option for execution.
# Return to root and execute the run script
cd ~/dev/celeste
./build.sh dev-run

ln -sf "$(realpath libffmpeg_recorder.so)" ~/dev/celeste/celeste_extensions/plugins/libffmpeg_recorder.so
