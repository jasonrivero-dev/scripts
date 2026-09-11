cd ~/dev/celeste 
cd back_end
cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=~/dev/celeste/back_end/cmake-build-relwithdebinfo/build/RelWithDebInfo/generators/conan_toolchain.cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_PREFIX_PATH=~/dev/celeste/deps/libtorch -DCMAKE_CUDA_COMPILER=/usr/bin/nvcc -S . -B cmake-build-relwithdebinfo
cd cmake-build-relwithdebinfo
ninja celeste

./celeste ../../ noveye-local-novai.cfg
./celeste ../../ noveye-local-main.cfg
