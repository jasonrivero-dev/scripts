// Copyright (c) Novarc Technologies Inc. All rights reserved.
//
// Manual GPU-box verification tool for SW-3035, not part of the automated test suite.
// Starts a real recording and never shuts it down cleanly -- run via crash_repro.sh,
// which SIGKILLs this process mid-recording to simulate a crash/power-loss, then checks
// whether the resulting file is still a valid, demuxable MP4.

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h> // getpid

#include <spdlog/spdlog.h>
#include <spdlog/sinks/stdout_color_sinks.h>

#include "cfg_loader.h"
#include "default_config.h"
#include "Recorder.h"
#include "RecorderFactory.h"
#include "plc_status.h"
#include "plc_data_service.h"
#include "system_manager.h"
#include "frame.h"
#include "utils.h"
#include "util/LogFactory.hpp"
#include "util/MetricsFactory.hpp"

// --- LINKER STUBS (mirrors RecorderTests.cpp exactly -- this binary doesn't link main.cpp either) ---
std::shared_ptr<SystemServices> GetSystem() { return {}; }
std::string GetRunName() { return "crash_repro"; }
std::chrono::microseconds GetReferenceTimeSinceEpoch() { return std::chrono::microseconds(0); }
std::optional<celeste::NoveyeDataMessage> GetLastPlcData() { return std::nullopt; }

struct MockPlcStatus : PlcStatus
{
    explicit MockPlcStatus() : PlcStatus({}) {}
    int GetWeldMsgVersion() const { return 4; }
    void Shutdown() {}
    bool IsRunning() const { return true; }
    bool ReadMessage() { return true; }
};

int main(int argc, char** argv)
{
    if (argc < 2) {
        std::cerr << "Usage: crash_repro_helper <output.mp4>\n";
        return 1;
    }
    std::string outFile = argv[1];

    static LogFactory log_factory("/tmp");
    log_factory.initialize({ LogFactory::Outputs::Console }, spdlog::level::debug);
    MetricsFactory::initialize("/tmp");

    CfgLoader params(Config::GetDefaultString());
    uint16_t width = params.ValOf<uint16_t>("camera.image width");
    uint16_t height = params.ValOf<uint16_t>("camera.image height");

    // Plugins::list_plugins()'s default discovery assumes a binary sitting directly in the
    // build root (like celeste does). This binary lives one level deeper, at <build_dir>/test/,
    // which throws that math off by a directory -- compensate with an explicit override that
    // strips the extra "test" component, so it lands on the same plugins/ celeste itself finds.
    std::filesystem::path binDirOverride = Utils::GetExecutablePath().parent_path().parent_path();

    auto plcMock = std::make_shared<MockPlcStatus>();
    auto recorder = RecorderFactory::Create(params, outFile, width, height, plcMock, binDirOverride);

    spdlog::info("crash_repro_helper: recording to {} ({}x{}), pid={}", outFile, width, height, getpid());
    recorder->Start();

    // Real per-frame noise, not a static all-zero buffer: a constant frame compresses to
    // almost nothing, and that trickle of encoded bytes may never fill libavformat's internal
    // I/O buffer enough to actually flush to disk -- which would silently defeat the whole
    // point of this repro (fragments only protect data that's actually reached the file).
    std::vector<uint8_t> data(static_cast<size_t>(width) * height);
    uint64_t frameCounter = 0;

    // Intentionally no Shutdown() call anywhere -- this process only ever exits via
    // an external signal (crash_repro.sh sends SIGKILL), simulating a genuine crash.
    while (true) {
        for (auto& b : data) {
            b = static_cast<uint8_t>(rand());
        }
        auto frame = std::make_shared<Frame>(
            0, 0, width, height, frameCounter,
            Frame::Dur_t(frameCounter * 33), // ~30fps
            PixelFormat::Mono8, data);

        recorder->QueueRecord(frame);
        ++frameCounter;
        std::this_thread::sleep_for(std::chrono::milliseconds(33));
    }

    return 0; // unreachable
}
