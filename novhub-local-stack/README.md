# novhub-local-stack

Brings up the full local NovHub stack for manual validation — the weld-data path (PLCSIM →
NovData → an OpenSearch loader → NOVAPI → NovApp) and the control path (LUNA → `plc-node` →
PLCSIM) — in the order the stack actually needs, idempotently, stopping at the first step that
needs a `sudo` command, a build, or a manual terminal. Replaces hand-walking
`~/dev/presentations/novhub-local-stack/NOVHUB_LOCAL_RUNBOOK.md` step by step.

Not a standalone application: it orchestrates seven other checkouts
(`~/dev/NovApi`, `~/dev/NovData`, `~/dev/NovSync`, `~/dev/novhub`, `~/dev/plc_simulator`,
`~/dev/plc-node`, and this repo's own `luna/run-luna.sh`) plus Docker and the robot's own
`/var/opt/novarc/configure`. It does not build, install, or run anything `sudo`-gated — those
steps always print the exact command, the terminal to run it in, and the expected result, then
stop.

## Usage

```bash
./novhub-local-stack/run-novhub.sh up      # bring the automatable parts up, in order
./novhub-local-stack/run-novhub.sh status  # report every component's state, change nothing
./novhub-local-stack/run-novhub.sh down    # stop everything this script started; keeps data
./novhub-local-stack/run-novhub.sh sync    # load the latest weld into OpenSearch, then NovSync
./novhub-local-stack/reset.sh --all        # dev-hygiene: wipe containers/data for a clean retest
```

`up` stops at the first step that fails or needs a manual action; rerun it once that's done and
it continues from there. `status` never stops early and never changes anything. `sync` is not
part of `up` — run it after each simulated weld to see it reflected in NovApp.

## Prerequisites

`up`/`status` check these first (`prereqs_check`) and stop if any are missing:

- Docker, Node.js/npm, the .NET 6 SDK, `git-lfs`, `python3`, `gh`, Docker Compose
- `vm.max_map_count >= 262144` (OpenSearch's own requirement) — prints the exact `sudo sysctl`
  command if it's lower

## The four secrets

Each is prompted once, only for the step that still needs it, read with no echo, and never
written to disk or logged by this script:

| Secret | Prompted by | What it's for |
| --- | --- | --- |
| Postgres superuser password | `novdata_up`, first run only | NovData's own Postgres container |
| `novdata` role password (`SWR_DB_KEY`) | `novdata_up`, every run | NovData's app process, and the loader/NovSync in `sync` |
| Robot API key (`SECRET_KEY`) | `novapi_up`, first run only | Seeded into NOVAPI as the robot's `api_key`; also what NovSync sends as `x-api-key` in `sync` |
| NovApp sign-in password (`LOCAL_PASSWORD`) | `novapi_up`, first run only | The seeded NovApp user's password |

The robot's own identity (`SWR_ID`, `SWR_NUMBER`, `SWR_CUSTOMER`, `SWR_LOCATION`) is read
read-only from `/var/opt/novarc/configure` — never invented, never defaulted. If that file is
missing or malformed, the script stops rather than guessing. That file's other entries (cloud
credentials, `SWR_DB_KEY` for a different, installed database) are never read, printed, or
copied anywhere.

## What `down` does and doesn't do

`down` stops every component this script started or manages — `docker stop` (not `rm`) for
OpenSearch/NovData/NOVAPI's Postgres containers, and a pidfile-tracked process-group kill for
NovData/NOVAPI/NovApp's background processes — leaving data and installs intact so the next `up`
picks up where it left off. It never uninstalls anything, never removes a container, and never
touches PLCSIM/`plc-node`/LUNA (it never started them). The runbook's full "Cleanup" section
(removing containers, uninstalling PLCSIM/`plc-node`, deleting NovSync's venv) stays manual — see
the runbook directly.

For dev-hygiene resets between test runs (wiping a container's data entirely, not just stopping
it), use `./novhub-local-stack/reset.sh` instead — see its own `--help`.

## Manual steps (PLCSIM, `plc-node`, LUNA)

These three are always check-only. `up`/`status` print the exact command, which terminal to run
it in, and the expected result, then stop (or, for LUNA, always print the reminder — there is no
way to check a desktop window from a script):

- **PLCSIM**: build the `.deb` (T1), `sudo apt install` it (T1), move its REST port to
  `127.0.0.1:8081` (T1, `sudoedit`), `sudo systemctl enable --now plc-simulator` (T1).
- **`plc-node`**: build the `.deb` (T1), `sudo apt install` it (T1), point its config at PLCSIM
  (T1, a printed `sudo sed` one-liner, not interactive editing), create its log directory (T1),
  start it (its own terminal, kept running).
- **LUNA**: start the backend (T5, `run-luna.sh backend`) and confirm the frontend window is
  open (T6, `run-luna.sh frontend`, needs the real desktop display).

See `~/dev/presentations/novhub-local-stack/NOVHUB_LOCAL_RUNBOOK.md` for the full procedure
these steps are drawn from, including starting a simulated weld and the closing validation.
