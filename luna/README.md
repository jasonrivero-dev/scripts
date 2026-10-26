# Luna local build/run scripts

Native (no Docker) build and run tooling for `~/dev/luna`, since `build_docker.sh` can't
authenticate its S3 pulls on this machine (see comment at the top of `build-backend.sh`).

## Quick start: run Luna now

Everything is already built and installed. Two terminals:

```
~/dev/scripts/luna/run-luna.sh backend
```
```
~/dev/scripts/luna/run-luna.sh frontend
```

The frontend window should come up after a few seconds. Backend logs go to both the terminal
and `/tmp/luna-logs/`.

## Manual QA: NovEye Autonomy licensing

1. Start both (above). Go to the screen with the Autonomy toggle (review/setup screen).
2. If the `noveye` entitlement is `granted` (check with `lictl status`), the toggle appears.
   If not granted/missing, it won't appear at all — that's correct, not a bug.
3. To test a change: edit the entitlement in the licenses dashboard, then **stop both
   terminals (Ctrl+C) and start them again** — the license is only decided once at startup,
   so a running instance won't notice the change until restarted. That's the point of this
   fix: it used to re-check every 60s and could flip the toggle off mid-weld; now it only
   decides at startup and freezes for the run.
4. To test "stays on even if the daemon drops mid-run": with the toggle already showing,
   run `sudo systemctl stop novarc-licensing` **without restarting Luna** — the toggle should
   stay exactly as it was. `sudo systemctl start novarc-licensing` to bring the daemon back.

## Scripts

### `build-backend.sh` — Go backend only (build/vet/test)

| Command | What it does |
|---|---|
| `deps` | Clones missing `third/*` proto repos via `./build_docker.sh --deps-only` |
| `toolchain` | Fetches pinned `protoc`/`flatc`/Go plugins (cached in `.cache/`) |
| `generate` | Runs the Go-side codegen (mirrors `Makefile`'s `generate_flatbuffers`/`generate_grpc`) |
| `build` | `go build ./...` + `go vet ./...` |
| `test` | `go test ./...` |
| `all` | All of the above, in order |

### `run-luna.sh` — run or package the whole app

| Command | What it does | Needs sudo? |
|---|---|---|
| `config` | Installs `/opt/novarc/apps/luna/etc/config.toml` (one-time) | Yes, first run only |
| `binary` | Builds `luna-backend/luna` | No |
| `frontend-toolchain` | apt deps for Flutter Linux + fetches Flutter 3.19.5 SDK | Only if apt packages are missing |
| `frontend-generate` | Dart flatbuffers, proto copy, well-known protobuf types, `build_runner build` | No |
| `backend` | Runs `./luna` in the foreground | No |
| `frontend` | Runs `flutter run -d linux` in the foreground | No |
| `bundle [version]` | `flutter build linux --release` + `deb/package.sh` → installable `.deb` | No |
| `all` | `config` + `binary` + `frontend-toolchain` + `frontend-generate`, then tells you to run `backend`/`frontend` yourself | First run only |

`sudo` steps need a real terminal (can't be run by an agent/non-interactive tool) — run them
yourself if a fresh checkout needs them again.

## Packaging a `.deb` for the testbench

```
~/dev/scripts/luna/run-luna.sh bundle
```

Output: `~/dev/luna/package/luna-ubuntu_22.04-x64-<version>.deb`. Install on the testbench the
normal way (`sudo dpkg -i ...` or whatever the testbench's usual install step is).

## Re-running after pulling new code

```
~/dev/scripts/luna/run-luna.sh binary              # backend changed
~/dev/scripts/luna/run-luna.sh frontend-generate   # proto/flatbuffer schemas changed
```
Then `backend`/`frontend`/`bundle` as above. `config`/`frontend-toolchain` don't need re-running
unless the config file gets deleted or new system packages are needed.
