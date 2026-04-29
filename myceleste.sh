#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Navigate to the project root
cd ~/dev/celeste
BUILD_CONFIG=RelWithDebInfo
BASE_DIRECTORY=$PWD
# Clean up old build directories
rm -rf ./back_end/build ./back_end/libs/ffmpeg_recorder/build

echo "Building dependencies..."
    pushd third/metrics-cpp > /dev/null
    cmake . -DCMAKE_INSTALL_PREFIX="${BASE_DIRECTORY}/deps/metrics-cpp"
    cmake --build . --target metrics --config $BUILD_CONFIG
    cmake --install .
    popd > /dev/null


# Move to back_end and configure the project with CMake
cd back_end
cmake -G Ninja \
  -DENABLE_COVERAGE=ON \
  -DCMAKE_TOOLCHAIN_FILE=~/dev/celeste/back_end/cmake-build-relwithdebinfo/build/RelWithDebInfo/generators/conan_toolchain.cmake \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_PREFIX_PATH=~/dev/celeste/deps/libtorch \
  -DCMAKE_LIBRARY_PATH=~/dev/celeste/build \
  -DCMAKE_CUDA_COMPILER=/usr/bin/nvcc \
  -S . -B cmake-build-relwithdebinfo
  
# Build the specific target
cd cmake-build-relwithdebinfo
ninja celeste

# Return to root and execute the run script
cd ~/dev/celeste
./build.sh dev-run
