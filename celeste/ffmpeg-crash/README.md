# ffmpeg-crash — SW-3035 crash-resilience verification

Manual verification tool for SW-3035 (corrupt captures crashing VLC on customer machines).
Confirms that a recording killed mid-write (crash, OOM, power loss) still leaves a valid,
playable MP4, thanks to the fragmented-MP4 fix in `FfmpegRecorder::Init()`
(`back_end/libs/ffmpeg_recorder/src/ffmpeg_recorder.cpp` in the celeste repo).

Lives here, outside the celeste repo, per review feedback that it's diagnostic scaffolding,
not part of the shipped fix. It still builds through celeste's real CMake graph (needed
because `nov_core` is an OBJECT library with no prebuilt artifact to link against from
outside) — `run.sh` stages the source into celeste, builds it there, runs the repro, then
tears the staging back out so celeste's tracked tree never carries a diff.

**Not part of `ctest`/CI** — this requires real NVENC hardware, which CI doesn't have.
Run it manually on a GPU box after any change to the recorder's init/muxer path.

## Files

- `crash_repro_helper.cpp` — a plain `main()` (no Catch2). Starts a real recording via
  `RecorderFactory::Create()` and loops forever queuing frames with real per-frame noise
  (not static data — a constant frame compresses to almost nothing and may never fill
  libavformat's I/O buffer enough to actually reach disk, which would silently defeat the
  whole point of this repro). It deliberately never calls `Shutdown()` — the process only
  ever exits via an external signal, simulating a genuine crash.
- `crash_repro.sh` — launches the helper, waits, sends `SIGKILL`, then checks the resulting
  file with `ffprobe`.
- `crash_repro_target.patch` — the CMake hunk (`add_executable(crash_repro_helper ...)`)
  that `run.sh` applies to celeste's `back_end/test/CMakeLists.txt` for the duration of a
  run, then reverts.
- `run.sh` — the stage → build → run → teardown lifecycle described above.

## Running it

```
./run.sh
```

Requires a configured host build at `~/dev/celeste/back_end/cmake-build-RelWithDebInfo`
(from `dev-build.sh` in this same `~/dev/scripts` directory) — `run.sh` builds the
`crash_repro_helper` target into that existing tree, it doesn't configure its own.
Override the celeste checkout or build config with `CELESTE_ROOT=... BUILD_CONFIG=... ./run.sh`.

Expected: `PASS: file is valid after forced kill` with the fix in place. Reverting the
`movflags=frag_keyframe+empty_moov` change in `Init()` and rebuilding
(`ninja -C ~/dev/celeste/back_end/cmake-build-RelWithDebInfo ffmpeg_recorder`) should
reproduce `FAIL` ("moov atom not found") — that's the actual before/after evidence for the
ticket.

The script prints the detected GPU (`nvidia-smi -L`) before running, and fails fast with a
clear message if no GPU is present rather than silently doing something meaningless.

## Why the binary needs `binDirOverride`

`crash_repro_helper` builds one directory deeper (`<build_dir>/test/crash_repro_helper`)
than `celeste` itself (`<build_dir>/celeste`), which throws off `Plugins::list_plugins()`'s
default relative-path plugin discovery by one directory level. The helper compensates with
an explicit `binDirOverride` computed from its own executable path
(`Utils::GetExecutablePath().parent_path().parent_path()`) — if you copy this binary
somewhere else, that assumption may need revisiting.
