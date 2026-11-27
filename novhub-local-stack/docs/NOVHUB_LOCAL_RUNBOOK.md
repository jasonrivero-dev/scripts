# NovHub local stack — browser network analysis

For inspecting NovApp's own network behavior (Network tab, HAR captures, request patterns) -
not for validating the real simulated-hardware chain. That's a different, heavier runbook (ask
if that's what you actually need - PLCSIM/NovData/LUNA). This one skips all of it: no PLCSIM, no
NovData, no `sudo`, no weld to trigger - `perf-seed.sh` writes synthetic weld data straight into
OpenSearch and NovApi's own Postgres.

Everything below is a script in `~/dev/scripts/novhub-local-stack/`. No bare `docker run`,
`curl`, or hand-typed SQL. Each is idempotent - safe to run again, it checks state first and
prints `already ...` when there's nothing to do.

**Passed means:** you open `http://localhost:5173`, sign in, open a robot's Analytics page, and
see weld runs.

## 1. Bring up the stack (3 components only)

```bash
cd ~/dev/scripts/novhub-local-stack
./opensearch.sh start
./novapi.sh start
./novapp.sh start
```

Each prints `ok: ...` when it's up; run them again any time. First run only: `novapi.sh start`
prompts once for two secrets, to seed this machine's own real robot identity (from
`/var/opt/novarc/configure`) - unrelated to this analysis and not the login you'll actually use
in step 3, just something `novapi.sh start` always does on a fresh database. It also brings up
a local MinIO container by itself - nothing to do for that.

## 2. Seed synthetic weld data

```bash
./perf-seed.sh seed
```

One command: 10 synthetic robots (`900001`-`900010`) x 2,000 runs each, straight into OpenSearch
and NovApi's Postgres. Prints `already seeded` on a rerun - safe to call again. The seeded
test login is written once to `.state/secrets/perf-test-user.secret` (0600, never printed to
the console) - read that file for the sign-in password for step 3; the email half is always
`hub106-perf-test@local.synthetic`.

## 3. Open the browser

1. Go to `http://localhost:5173`.
2. Sign in as `hub106-perf-test@local.synthetic` with the password from step 2's secret file.
3. Pick robot `PERF-TEST-900001` from the sidebar, open its **Analytics** page (or any page
   listing weld runs) - the URL becomes `/PERF-TEST-900001/analytics`.

Expect 2,000 runs to show up. Pick whichever of the ten robots (`PERF-TEST-900001` through
`PERF-TEST-900010`) the analysis needs - all ten carry the same shape of data.

## 4. Capture and analyze

Two capture options - pick one per page, or use both for comparison:

- **Manual (DevTools)**: follow
  [NETWORK_TAB_GUIDE.md](hub106-perf-results/NETWORK_TAB_GUIDE.md) §"Opening it" through
  §"Exporting a HAR (exact steps)" - do not use the old "right-click → Save all as HAR"
  instruction if you've seen it elsewhere; current Chrome moved this to a toolbar export icon
  with two options, and that guide has the verified current steps (use "Export HAR
  (sanitized)").
- **Automated (Playwright, no browser needed)**:
  ```bash
  ./perf-capture.sh --page analytics --robot-name PERF-TEST-900001 --out <dir>
  ```
  Drives the page itself, dismisses the first-visit tour modal, and saves the HAR + a
  Performance trace + a `metrics.json` (time to usable, request counts, scripting time, longest
  task) - see `./perf-capture.sh --help`.

**Capture both the list-load and a row-click separately - they're not the same traffic.** The
Analytics page's list view already fires one N+1 set of `weld_test_reports` calls on load; a row
click mounts `WeldInformation`, which fires its own separate per-run calls. `perf-capture.sh`
does the click automatically for `--page analytics`; doing it by hand in DevTools means
exporting a HAR, clicking a row, then exporting a second HAR before reloading.

### Turn a HAR (and/or NovApi's own log) into one graphical report

```bash
cd ~/dev/scripts/novhub-local-stack
./perf-report.sh --har <path-to-the.har> --out <dir>
```

Builds `<dir>/report.html` - open it directly in a browser, nothing to install. Add more flags
to add more sections to the same report, nothing to re-run from scratch:

| Flags | Adds |
|---|---|
| `--har <path>` alone | per-endpoint request table, peak concurrency / staircase detection, a request timeline |
| `--novapi-log <path>` alone | NovApi's own server-measured time per endpoint (no browser involved) |
| both together | a browser-vs-server comparison per request, matched by endpoint + closest start time (within 5s) - the report states exactly how many matched and how many didn't, by endpoint and why, never a silent drop |
| `--os-container <name> --pg-container <name>` (with `--novapi-log`) | a NovApi/OpenSearch/Postgres/Rest time breakdown per endpoint - turn slow-query logging on first: `./perf-slowlog.sh on` (and `off` after, it's noisy) |

Running it again with more flags against the same `--out` overwrites `report.html`/`data.json`
with the combined version - it doesn't create a second file. Full reference:
`./perf-report.sh --help`.

## Checking and stopping

```bash
./run-novhub.sh status   # reports opensearch/novapi/novapp's state, changes nothing
./run-novhub.sh stop     # stops everything (keeps all data) - rerun step 1 to resume
```

```bash
./perf-seed.sh remove    # delete exactly what seed created, nothing else
```

## If something doesn't add up

Each script's own output names the specific thing to check next (a log file under `.state/`, a
docker log). For the real device-simulation path (PLCSIM/NovData/LUNA/`plc-node`), the four
secrets in full, or OpenSearch manual recovery, see `novhub-local-stack/README.md` - this
runbook defers to it rather than repeating it.
