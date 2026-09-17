# Development and Operations Scripts

A collection of local development, build, test, telemetry, licensing, and diagnostic helpers used alongside the Novarc/Celeste software stack.

This repository is **not a standalone application**. Most commands assume a Linux development machine, a Celeste checkout at `~/dev/celeste`, and other Novarc services or tools installed in their normal system locations. Read each script's help output before using it.

The repo is organized by topic:

| Folder | Purpose |
| --- | --- |
| [`celeste/`](celeste/) | Celeste host build, launch, setup, logging, coverage, metrics/PLC helpers, FFmpeg crash repro |
| [`licensing/`](licensing/) | `novarc-licensing` CLI wrapper, EC2 QA deploy/uninstall, Keygen checkout test, TPM hardware ID |
| [`telemetry/`](telemetry/) | Vector/Prometheus/Grafana stack control, test environment loader, mocks, configure templates |
| [`tools/`](tools/) | Diverse one-off utilities: Jira CLI wrappers, Markdown-to-HTML converter, Markdown-to-Google-Docs converter |
| [`lib/`](lib/) | Shared logging helpers sourced by scripts in `celeste/` and `telemetry/` |
| [`docs/`](docs/) | Personal VS Code how-to and IDE troubleshooting notes |
| [`gen-coverage.sh`](gen-coverage.sh) | The one script that stays at repo root — see [Coverage](#coverage) below |

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
- `telemetry/install_metrics_deps.sh`, `celeste/create_dirs.sh`, `telemetry/telemetry.sh`, the mock scripts, and `celeste/celeste-setup.sh` write under `/var`, `/opt`, or system service locations.
- `telemetry/vector-test.sh` exports AWS credentials into the current shell and must be sourced, not executed.
- `tools/jiracli/get-ticket.sh` and `tools/jiracli/get-my-tickets.sh` read `tools/jiracli/token` and pass the token to the Jira CLI. That file is gitignored, not tracked; treat it as a secret and never commit it. If it has ever contained a real token, rotate it.
- `licensing/keygen/test_keygen.sh` reads local Keygen credentials from files under `~/dev` and sends a request to Keygen.
- `licensing/licadmin` generates signing material and can install licenses into a running system daemon.
- `licensing/licadmin-ec2-deploy --uninstall` purges the `novarc-licensing` package and deletes the deploy directory on the configured EC2 box after a confirmation prompt.
- `tools/md2word/convert.sh` uploads to Google Drive using an OAuth client secret and cached token, both defaulting to `$HOME/.config/md2word/` — entirely outside this repository. Never commit either; if you ever point `MD2WORD_CLIENT_SECRET`/`MD2WORD_TOKEN_CACHE` at a path inside the repo, gitignore it first.
- `telemetry/sync_telemetry.sh reset` deletes Vector state and logs under `/var/lib/vector` and `/var/log/vector`.
- The telemetry mock scripts append data directly to production-style log paths. Use them only on an intended test host.

Prefer environment files outside this repository, restrict their permissions, and inspect a script before running it with elevated privileges.

## Prerequisites

Install only the dependencies needed for the workflow you are using. Common requirements include:

- Ubuntu/Linux shell utilities: Bash, `coreutils`, `find`, `grep`, `jq`, `curl`, `wget`, `ssh`, `tar`, and `sudo`.
- Celeste host development: a sibling checkout at `~/dev/celeste`, CMake, Ninja, Conan, a C++ toolchain, CUDA/NVCC, libtorch, and Celeste's third-party dependencies. Run `~/dev/celeste/build.sh --setup-clion` first.
- Coverage: `lcov` and `genhtml`.
- Markdown conversion: Pandoc, Node.js/npm, `mermaid-filter`, Chromium-compatible browser tooling, and `xdg-open` when using browser output.
- Markdown to Google Docs: the above, plus Python 3 and `pip install -r tools/md2word/requirements.txt`, plus a one-time Google Cloud OAuth setup (see `tools/md2word/README.md`).
- Licensing: Rust/Cargo, the separate `~/dev/Licensing` and `~/dev/licensing-poc` checkouts, and optionally the installed `lictl` command.
- Telemetry: Docker, Vector `0.56.0`, AWS credentials, and the target Novarc service configuration. `sudo ./telemetry/install_metrics_deps.sh` installs or verifies several host dependencies.
- Jira: the Jira CLI (`jira`) and a valid API token in the location expected by the Jira scripts.
- Crash reproduction: a configured Celeste host build and an NVIDIA GPU with NVENC; `ffprobe` is used to validate the resulting MP4.
- TPM test: `tpm2-tools` for the TPM-backed path; the script has an OS/CPU fallback.

The scripts do not provide a single dependency installer for all workflows. `telemetry/install_metrics_deps.sh` is specifically for Docker, ACL utilities, and Vector telemetry dependencies.

## celeste/

The preferred host-side wrapper around the separate Celeste checkout, plus every celeste-specific helper that used to sit at the repo root.

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

### Coverage

Coverage helpers target a Celeste checkout and use LCOV:

```bash
# Capture, filter, and generate an HTML report
./gen-coverage.sh

# Select another sibling project directory and open the result
./gen-coverage.sh -t celeste -o

# Convert an existing coverage_filtered.info into the host-mapped report
./celeste/gen-coverage-html.sh
```

Reports are written below the Celeste checkout, normally under `reports/host_coverage_report`. `gen-coverage-html.sh` expects `coverage_filtered.info` to already exist; `gen-coverage.sh` produces `filtered.info`, so check the expected tracefile before combining these workflows. `gen-coverage.sh` is the one script that stays at the repo root: it's a generic, parameterized (`-t <target>`) tool that can target any sibling project under `~/dev`, not just Celeste, even though Celeste is its default target.

### Metrics and PLC data

```bash
# Create a synthetic Grafana/Prometheus-style Celeste log
./celeste/grafana.sh

# Send the three supported UDP PLC message shapes to localhost
./celeste/send_plc_msg.py
```

`celeste/create_dirs.sh` creates the common Celeste runtime/log directories and assigns them to the current user:

```bash
./celeste/create_dirs.sh
```

### Logs

```bash
# Follow the newest log; optionally filter case-insensitively
./celeste/tail-log.sh
./celeste/tail-log.sh licensing
```

### FFmpeg crash resilience

[`celeste/ffmpeg-crash/`](celeste/ffmpeg-crash/) contains a manual SW-3035 verification, not a CI test:

```bash
./celeste/ffmpeg-crash/run.sh
CELESTE_ROOT=/path/to/celeste BUILD_CONFIG=Debug ./celeste/ffmpeg-crash/run.sh
```

It stages a helper into the Celeste source tree, builds it through Celeste's CMake graph, kills the recorder with `SIGKILL`, and validates the resulting MP4 with `ffprobe`. It requires a configured host build and real NVIDIA NVENC hardware. See [`celeste/ffmpeg-crash/README.md`](celeste/ffmpeg-crash/README.md) for the expected PASS/FAIL behavior.

## licensing/

Everything here supports the `novarc-licensing` product.

### licadmin

```bash
./licensing/licadmin keygen
./licensing/licadmin hwid
./licensing/licadmin lazy-issue [customer_name] [app_name]
./licensing/licadmin <other licensing-cli arguments>
```

A wrapper around the separate `~/dev/Licensing` Rust workspace. `lazy-issue` creates a one-year development license with a five-day grace period and installs it with `lictl` when available. It may create or use `~/.licadmin_keys`, invoke `sudo`, and write a temporary `dev_license.lic` in the current directory.

### licadmin-ec2-deploy

Builds the `novarc-licensing` .deb and example clients from `~/dev/licensing-poc`, copies them plus the installed-path-safe QA scripts to a QA EC2 box, and prints the manual provisioning steps to run over your own SSH session:

```bash
./licensing/licadmin-ec2-deploy
./licensing/licadmin-ec2-deploy --uninstall
```

`--uninstall` purges the package and deletes the remote deploy directory after a y/N confirmation prompt.

### Keygen checkout test

[`licensing/keygen/test_keygen.sh`](licensing/keygen/test_keygen.sh) is a separate online checkout test. It sources `~/dev/novarc-swr-license.keygen` and `~/dev/novarc-admin-token.keygen`, then calls the Keygen API with `curl` and formats the response with `jq`.

### TPM hardware ID

```bash
./licensing/tpm/test.sh
```

Derives an ID from a TPM 2.0 endorsement key and falls back to a stable OS/CPU-derived hash when TPM tooling or hardware is unavailable. It underlies the hardware-ID fingerprinting that `licadmin hwid` also produces.

## telemetry/

Everything here supports the Vector + Prometheus + Grafana observability stack.

### Install and control the telemetry stack

```bash
# Installs/verifies ACL, Docker CE, and Vector 0.56.0
sudo ./telemetry/install_metrics_deps.sh

# Control the systemd Vector service
./telemetry/telemetry.sh start
./telemetry/telemetry.sh status
./telemetry/telemetry.sh tail
./telemetry/telemetry.sh restart

# Destructive: stop Vector, remove its state/logs, and start from the log end
./telemetry/telemetry.sh reset
```

`telemetry.sh` controls the configured Vector service through `systemctl` and `journalctl`; inspect its `SERVICE_NAME` before use on another host.

### Load a test environment

`vector-test.sh` must be sourced so its exports remain in the calling shell:

```bash
source ./telemetry/vector-test.sh
source ./telemetry/vector-test.sh --config /path/to/configure
```

It reads the configure file, exports AWS and telemetry variables, creates `/tmp/vector-data`, and prints example Vector commands. It expects `AWS_IAM_ID` and `AWS_IAM_KEY` in the selected configure file. Configure file templates live in [`telemetry/config/`](telemetry/config/), which is gitignored; inspect a file before sourcing it.

### Generate or inject telemetry data

```bash
# Emit sample CameraNode, Luna, OdiumPM, or WSM metrics
./telemetry/mock/camera_mock.sh
./telemetry/mock/luna_mock.sh --value 12000
./telemetry/mock/odiumpm_mock.sh
./telemetry/mock/wsm_mock.sh
```

The mock scripts write beneath `/var/log/novarc/...` and may require the directories to exist first (see `celeste/create_dirs.sh` for the Celeste-specific paths).

### Sync telemetry from a robot

```bash
./telemetry/sync_telemetry.sh <ROBOT_ID>
```

This bundles telemetry folders on the remote robot and copies the archive locally using the configured AWS SSM profile and `novarc` user. Review the remote paths and profile in the script before using it with a new robot or environment.

## tools/

Diverse one-off utilities that don't belong to a specific product.

### Jira CLI

```bash
# View one or more issues, including the latest three comments
./tools/jiracli/get-ticket.sh SW-1234
./tools/jiracli/get-ticket.sh -p -c 5 SW-1234 SW-5678

# List the current user's issues
./tools/jiracli/get-my-tickets.sh
./tools/jiracli/get-my-tickets.sh -s 'In Progress' -l 25 -p
./tools/jiracli/get-my-tickets.sh -e SW-3373 -t SWR-LIC
```

Both scripts expect a token at `tools/jiracli/token` (resolved relative to the script's own location) and the Jira CLI to be installed. `get-my-tickets.sh` defaults to excluding Done issues unless an explicit status, epic, or title query is supplied.

### Markdown to HTML

Convert all Markdown files in a directory into standalone HTML with a table of contents, embedded resources, Novarc styling, and Mermaid support:

```bash
./tools/md2html/convert.sh -s /path/to/markdown -t /path/to/html
./tools/md2html/convert.sh -s /path/to/markdown -o
./tools/md2html/convert.sh -s /path/to/markdown -t /tmp/html -o -b google-chrome
```

The default target is `~/Documents`. The converter uses [`tools/md2html/novarc.css`](tools/md2html/novarc.css), [`tools/md2html/header.html`](tools/md2html/header.html), and the `mermaid-filter` executable. It writes a temporary `.puppeteer.json` in the current working directory and removes it on exit.

### Markdown to Google Docs

A separate tool from `md2html` above — does not touch it. Converts Markdown to `.docx`
locally (mirroring the source tree, same pattern as `md2html`), then uploads each file to a
Google Drive folder as a native Google Doc:

```bash
tools/md2word/convert.sh -s /path/to/markdown -g <drive_folder_id>
tools/md2word/convert.sh -s /path/to/markdown -n   # local .docx only, no Drive upload
```

Requires a one-time Google Cloud OAuth setup — see [`tools/md2word/README.md`](tools/md2word/README.md). Re-running against an already-uploaded file overwrites the existing Google Doc in place rather than creating a duplicate.

## lib/

[`lib/dev-log-lib`](lib/dev-log-lib) is the shared NOVARC-banner logging helper library. It's sourced by `celeste/dev-build.sh`, `celeste/celeste-setup.sh`, and `telemetry/vector-test.sh` — anything that wants the same colored/bannered log output. It's a plain library file, not something you run directly.

## docs/

Personal reference notes, not scripts:

- [`docs/VSCODE_HOWTO.md`](docs/VSCODE_HOWTO.md) — day-to-day VS Code tasks/launch configs for Celeste development.
- [`docs/VSCODE_IDE_TROUBLESHOOTING.md`](docs/VSCODE_IDE_TROUBLESHOOTING.md) — stale CMake source globs and IntelliSense problems.

These documents describe local `.vscode` files, which are ignored by this repository.

## Conventions

- Scripts are primarily Bash and are intended for Linux.
- Paths are often machine-specific and use `$HOME/dev`, `/opt/novarc`, or `/var/log/novarc`.
- Many scripts are diagnostic or personal development tooling rather than production-safe automation.
- Prefer the Celeste wrapper in `celeste/dev-build.sh` over the older [`celeste/build.sh`](celeste/build.sh) for current host builds.
- Keep credentials, generated reports, build outputs, and local IDE state out of version control. Review `.gitignore` before adding new generated artifacts.
