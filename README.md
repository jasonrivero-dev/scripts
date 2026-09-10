# Development and Operations Scripts

A collection of local development, build, test, telemetry, licensing, and diagnostic helpers used alongside the Novarc/Celeste software stack.

This repository is **not a standalone application**. Most commands assume a Linux development machine, a Celeste checkout at `~/dev/celeste`, and other Novarc services or tools installed in their normal system locations. Read each script's help output before using it.

## Quick Start

```bash
cd ~/dev/scripts

# See the main Celeste workflows and caveats
./celeste/dev-build.sh -hh

# Configure, build, and run the host test suite
./celeste/dev-build.sh -r

# Launch Celeste with the main local configuration
./celeste/dev-build.sh -l

# Follow the newest Celeste log across restarts
./celeste/tail-log.sh
```

For a fresh Celeste host setup, run Celeste's own dependency setup first:

```bash
cd ~/dev/celeste
./build.sh --setup-clion
cd ~/dev/scripts
./celeste/dev-build.sh -r
```

## Safety and Secrets

Several scripts change system state, require `sudo`, contact external services, or use credentials:

- `celeste/dev-build.sh -d` is destructive. It removes host build directories, `deps/`, and the Celeste repository's root `build/` before running the Docker test workflow. Use `-pd` afterward to restore both host build trees.
- `install_metrics_deps.sh`, `create_dirs.sh`, `telemetry.sh`, the mock scripts, and `celeste/celeste-setup.sh` write under `/var`, `/opt`, or system service locations.
- `vector-test.sh` exports AWS credentials into the current shell and must be sourced, not executed.
- `jiracli/get-ticket.sh` and `jiracli/get-my-tickets.sh` read `jiracli/token` and pass the token to the Jira CLI. Treat that file as a secret; do not commit or share it. If it has ever contained a real token, rotate it.
- `keygen/test_keygen.sh` reads local Keygen credentials from files under `~/dev` and sends a request to Keygen.
- `licadmin` generates signing material and can install licenses into a running system daemon.
- `sync_telemetry.sh reset` deletes Vector state and logs under `/var/lib/vector` and `/var/log/vector`.
- The telemetry mock scripts append data directly to production-style log paths. Use them only on an intended test host.

Prefer environment files outside this repository, restrict their permissions, and inspect a script before running it with elevated privileges.

## Prerequisites

Install only the dependencies needed for the workflow you are using. Common requirements include:

- Ubuntu/Linux shell utilities: Bash, `coreutils`, `find`, `grep`, `jq`, `curl`, `wget`, `ssh`, `tar`, and `sudo`.
- Celeste host development: a sibling checkout at `~/dev/celeste`, CMake, Ninja, Conan, a C++ toolchain, CUDA/NVCC, libtorch, and Celeste's third-party dependencies. Run `~/dev/celeste/build.sh --setup-clion` first.
- Coverage: `lcov` and `genhtml`.
- Markdown conversion: Pandoc, Node.js/npm, `mermaid-filter`, Chromium-compatible browser tooling, and `xdg-open` when using browser output.
- Licensing: Rust/Cargo, the separate `~/dev/Licensing` checkout, and optionally the installed `lictl` command.
- Telemetry: Docker, Vector `0.56.0`, AWS credentials, and the target Novarc service configuration. `sudo ./install_metrics_deps.sh` installs or verifies several host dependencies.
- Jira: the Jira CLI (`jira`) and a valid API token in the location expected by the Jira scripts.
- Crash reproduction: a configured Celeste host build and an NVIDIA GPU with NVENC; `ffprobe` is used to validate the resulting MP4.
- TPM test: `tpm2-tools` for the TPM-backed path; the script has an OS/CPU fallback.

The scripts do not provide a single dependency installer for all workflows. `install_metrics_deps.sh` is specifically for Docker, ACL utilities, and Vector telemetry dependencies.

## Celeste Development

The [`celeste/`](celeste/) directory contains the preferred host-side wrapper around the separate Celeste checkout.

### Host build and tests

```bash
# Reconfigure, build Celeste and test targets, then run host tests
./celeste/dev-build.sh -r

# Use the Debug build tree
./celeste/dev-build.sh -t Debug -r

# Rebuild the metrics dependency and build the host target
./celeste/dev-build.sh -m

# Enable coverage instrumentation while building/running tests
./celeste/dev-build.sh -c -r

# Remove host build artifacts and the recorder build directory
./celeste/dev-build.sh -cl

# Remove stale in-source CMake artifacts under third-party checkouts
./celeste/dev-build.sh -cd
```

`-r` deliberately re-runs CMake. This matters after adding, removing, or renaming C++ files because much of the Celeste tree uses `file(GLOB ...)` without `CONFIGURE_DEPENDS`. A plain Ninja build can otherwise use an outdated source list.

### Launching Celeste

```bash
# Main local configuration
./celeste/dev-build.sh -l

# NovAI local configuration
./celeste/dev-build.sh -l -a

# An explicitly deployed configuration
./celeste/dev-build.sh -l -f /opt/novarc/apps/celeste/etc/noveye.cfg
```

The launcher expects a built binary and manages host plugin symlinks so host binaries do not accidentally load Docker-built libraries. `celeste/celeste-setup.sh` creates a video-based local configuration with AI model files and disabled PLC communication:

```bash
./celeste/celeste-setup.sh
./celeste/dev-build.sh -l -f /opt/novarc/apps/celeste/etc/noveye.cfg
```

That setup expects:

- `~/dev/celeste-files/ai_nn/share/`
- `~/dev/celeste-files/original_image_mig.mp4`
- permission to create `/opt/novarc/apps/celeste/etc` and `/opt/novarc/apps/ai_nn`

### Docker test recovery

```bash
# Destructive Docker test; clears host artifacts first
./celeste/dev-build.sh -d

# Re-run Celeste dependency setup and rebuild both host configurations
./celeste/dev-build.sh -pd
```

The `-d` path clears host build state to avoid Celeste's dependency-copy nesting issue and Docker/host ABI mismatches. If recovery is needed manually:

```bash
cd ~/dev/celeste
./build.sh --setup-clion
cd ~/dev/scripts
./celeste/dev-build.sh -r
./celeste/dev-build.sh -t Debug -r
```

For a summary of the Celeste Makefile, use `./celeste/dev-build.sh -mt`. The detailed flag documentation and known build gotchas are available through `./celeste/dev-build.sh -hh`.

### Logs and VS Code

```bash
# Follow the newest log; optionally filter case-insensitively
./celeste/tail-log.sh
./celeste/tail-log.sh licensing
```

The personal VS Code notes are in [`celeste/VSCODE_HOWTO.md`](celeste/VSCODE_HOWTO.md). The troubleshooting guide covers stale CMake source globs and IntelliSense problems in [`celeste/VSCODE_IDE_TROUBLESHOOTING.md`](celeste/VSCODE_IDE_TROUBLESHOOTING.md). These documents describe local `.vscode` files, which are ignored by this repository.

## Coverage

Coverage helpers target a Celeste checkout and use LCOV:

```bash
# Capture, filter, and generate an HTML report
./gen-coverage.sh

# Select another sibling project directory and open the result
./gen-coverage.sh -t celeste -o

# Convert an existing coverage_filtered.info into the host-mapped report
./gen-coverage-html.sh
```

Reports are written below the Celeste checkout, normally under `reports/host_coverage_report`. `gen-coverage-html.sh` expects `coverage_filtered.info` to already exist; `gen-coverage.sh` produces `filtered.info`, so check the expected tracefile before combining these workflows.

## Telemetry

### Install and control the telemetry stack

```bash
# Installs/verifies ACL, Docker CE, and Vector 0.56.0
sudo ./install_metrics_deps.sh

# Control the systemd Vector service
./telemetry.sh start
./telemetry.sh status
./telemetry.sh tail
./telemetry.sh restart

# Destructive: stop Vector, remove its state/logs, and start from the log end
./telemetry.sh reset
```

`telemetry.sh` controls the configured Vector service through `systemctl` and `journalctl`; inspect its `SERVICE_NAME` before use on another host.

### Load a test environment

`vector-test.sh` must be sourced so its exports remain in the calling shell:

```bash
source ./vector-test.sh
source ./vector-test.sh --config /path/to/configure
```

It reads the configure file, exports AWS and telemetry variables, creates `/tmp/vector-data`, and prints example Vector commands. It expects `AWS_IAM_ID` and `AWS_IAM_KEY` in the selected configure file.

### Generate or inject telemetry data

```bash
# Create a synthetic Grafana/Prometheus-style Celeste log
./grafana.sh

# Emit sample CameraNode, Luna, OdiumPM, or WSM metrics
./mock/camera_mock.sh
./mock/luna_mock.sh --value 12000
./mock/odiumpm_mock.sh
./mock/wsm_mock.sh

# Send the three supported UDP PLC message shapes to localhost
./send_plc_msg.py
```

The mock scripts write beneath `/var/log/novarc/...` and may require the directories to exist first. [`create_dirs.sh`](create_dirs.sh) creates the common Celeste runtime/log directories and assigns them to the current user:

```bash
./create_dirs.sh
```

### Sync telemetry from a robot

```bash
./sync_telemetry.sh <ROBOT_ID>
```

This bundles telemetry folders on the remote robot and copies the archive locally using the configured AWS SSM profile and `novarc` user. Review the remote paths and profile in the script before using it with a new robot or environment.

## Diagnostics and Integration Checks

### FFmpeg crash resilience

[`FFMpegCrash/`](FFMpegCrash/) contains a manual SW-3035 verification, not a CI test:

```bash
./FFMpegCrash/run.sh
CELESTE_ROOT=/path/to/celeste BUILD_CONFIG=Debug ./FFMpegCrash/run.sh
```

It stages a helper into the Celeste source tree, builds it through Celeste's CMake graph, kills the recorder with `SIGKILL`, and validates the resulting MP4 with `ffprobe`. It requires a configured host build and real NVIDIA NVENC hardware. See [`FFMpegCrash/README.md`](FFMpegCrash/README.md) for the expected PASS/FAIL behavior.

### TPM hardware ID

```bash
./tpm/test.sh
```

The script attempts to derive an ID from a TPM 2.0 endorsement key and falls back to a stable OS/CPU-derived hash when TPM tooling or hardware is unavailable.

## Licensing

`licadmin` is a wrapper around the separate `~/dev/Licensing` Rust workspace:

```bash
./licadmin keygen
./licadmin hwid
./licadmin lazy-issue [customer_name] [app_name]
./licadmin <other licensing-cli arguments>
```

`lazy-issue` creates a one-year development license with a five-day grace period and installs it with `lictl` when available. It may create or use `~/.licadmin_keys`, invoke `sudo`, and write a temporary `dev_license.lic` in the current directory.

The [`keygen/test_keygen.sh`](keygen/test_keygen.sh) script is a separate online checkout test. It sources `~/dev/novarc-swr-license.keygen` and `~/dev/novarc-admin-token.keygen`, then calls the Keygen API with `curl` and formats the response with `jq`.

## Jira CLI Helpers

```bash
# View one or more issues, including the latest three comments
./jiracli/get-ticket.sh SW-1234
./jiracli/get-ticket.sh -p -c 5 SW-1234 SW-5678

# List the current user's issues
./jiracli/get-my-tickets.sh
./jiracli/get-my-tickets.sh -s 'In Progress' -l 25 -p
./jiracli/get-my-tickets.sh -e SW-3373 -t SWR-LIC
```

Both scripts expect a token at `~/dev/scripts/jiracli/token` and the Jira CLI to be installed. `get-my-tickets.sh` defaults to excluding Done issues unless an explicit status, epic, or title query is supplied.

## Markdown to HTML

Convert all Markdown files in a directory into standalone HTML with a table of contents, embedded resources, Novarc styling, and Mermaid support:

```bash
./md2html/convert.sh -s /path/to/markdown -t /path/to/html
./md2html/convert.sh -s /path/to/markdown -o
./md2html/convert.sh -s /path/to/markdown -t /tmp/html -o -b google-chrome
```

The default target is `~/Documents`. The converter uses [`md2html/novarc.css`](md2html/novarc.css), [`md2html/header.html`](md2html/header.html), and the `mermaid-filter` executable. It writes a temporary `.puppeteer.json` in the current working directory and removes it on exit.

## Repository Map

| Path | Purpose |
| --- | --- |
| [`celeste/`](celeste/) | Celeste host build, launch, setup, logging, and VS Code notes |
| [`FFMpegCrash/`](FFMpegCrash/) | Manual GPU-backed FFmpeg crash-resilience reproduction |
| [`config/`](config/) | Environment/configure file templates or links; inspect before sourcing |
| [`jiracli/`](jiracli/) | Jira issue query wrappers and token location |
| [`keygen/`](keygen/) | Keygen license checkout test |
| [`md2html/`](md2html/) | Markdown-to-HTML converter and presentation assets |
| [`mock/`](mock/) | Synthetic production-format telemetry emitters |
| [`tpm/`](tpm/) | Stable hardware-ID experiment |
| [`build.sh`](build.sh) | Older direct Celeste configure/build/run helper with hard-coded paths |
| [`create_dirs.sh`](create_dirs.sh) | Create and chown common Celeste runtime directories |
| [`gen-coverage.sh`](gen-coverage.sh) | Capture/filter/render LCOV coverage |
| [`gen-coverage-html.sh`](gen-coverage-html.sh) | Render a pre-existing filtered coverage tracefile |
| [`grafana.sh`](grafana.sh) | Write synthetic Celeste metric records |
| [`install_metrics_deps.sh`](install_metrics_deps.sh) | Install/check telemetry host dependencies |
| [`licadmin`](licadmin) | Licensing CLI wrapper and development-license helper |
| [`send_plc_msg.py`](send_plc_msg.py) | Send sample PLC UDP packets to localhost |
| [`sync_telemetry.sh`](sync_telemetry.sh) | Bundle and retrieve robot telemetry |
| [`telemetry.sh`](telemetry.sh) | Manage the Vector systemd service |
| [`vector-test.sh`](vector-test.sh) | Source a Vector/AWS test environment |

## Conventions

- Scripts are primarily Bash and are intended for Linux.
- Paths are often machine-specific and use `$HOME/dev`, `/opt/novarc`, or `/var/log/novarc`.
- Many scripts are diagnostic or personal development tooling rather than production-safe automation.
- Prefer the Celeste wrapper in `celeste/dev-build.sh` over the older root [`build.sh`](build.sh) for current host builds.
- Keep credentials, generated reports, build outputs, and local IDE state out of version control. Review `.gitignore` before adding new generated artifacts.
