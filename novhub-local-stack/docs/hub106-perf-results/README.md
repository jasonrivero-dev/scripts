# HUB-106 Local-Stack Performance: Before/After Procedure

This document defines the **local-stack** HUB-106 performance workflow — frozen
dataset, automated endpoint baseline, browser walkthrough, and local Before/After
comparison. Its existing report artifacts are historical local-stack measurements;
they are separate from the dev dataset captures. For the manual cloud-BEFORE/local-code-AFTER
DevTools workflow, use
[HUB-106-BEFORE-AFTER-PERFORMANCE-RUNBOOK.md](../HUB-106-BEFORE-AFTER-PERFORMANCE-RUNBOOK.md).
Other HUB-106 docs should link to the relevant workflow rather than mix them.

## 1. The frozen dataset

- **What:** 2,000 runs — 1,000 each on two synthetic robots (`910001`, `910002`), 3,000 points
  per run — ingested through the real `opensearch-ingester` code path (not hand-written docs).
- **Why this way:** the goal is realistic data shape and volume, not synthetic shortcuts — see
  §5 for how faithful this is to the real ingestion path, and the open question on scale.
- **Confirm it's unchanged** (idempotent, read-only, run from `~/dev/scripts/novhub-local-stack`):
  ```bash
  curl -s "http://127.0.0.1:9200/novhub-local-ingester/_count" -H 'Content-Type: application/json' \
    -d '{"query":{"terms":{"robot.robot_id":[910001,910002]}}}'
  ```
  Expected: `{"count":6002000,...}` (2,000 runs × 3,001 docs each). A different count means the
  dataset changed — stop and reconcile before measuring anything.

## 2. Start the stack

```bash
cd ~/dev/scripts/novhub-local-stack
./opensearch.sh start
./novapi.sh start   # also brings up the local MinIO (S3 mock) automatically - no manual step
./novapp.sh start
```

Expected: each prints `ok: ...` at the end. `novapi.sh start` additionally prints
`created`/`already exists` lines for MinIO and the bucket — if MinIO was ever removed, this
recreates it, but does not touch the dataset in OpenSearch/Postgres.

### Brand check — NovAI, not SWR

**TAS (the customer with the reported issue) runs NovAI robots only**, so every measurement
here must be running the NovAI build on both sides. `novapi.sh start`/`novapp.sh start` set
this themselves (`IS_NOVAI`/`VITE_IS_NOVAI`, explicitly stripped of any ambient shell value
first — see `steps/novapi.sh`/`steps/novapp.sh`) and **fail loudly and refuse to start** if the
app doesn't come up as NovAI. Check it directly any time with:

```bash
./brand-check.sh
```

Expected: `NovApi brand: NovAI` and `NovApp brand: NovAI`, exit code 0. Every `perf-harness-a.sh`/
`perf-sweep.sh`/`perf-report.sh` run also records this in its own output (`"brand": {...}` in
`results.json`/`size-sweep.json`/`data.json`, and in every `report.html`'s header) and the
`.sh` tools refuse to measure at all if either side isn't NovAI.

The SWR-brand v1 pages (`weld_run`, `weld_run_files`, reading Postgres directly) are **parked,
not needed for TAS** — no Postgres `weld_run` seeding is done here, only the NovAI/OpenSearch
path described in §1.

## 3. Automated endpoint baseline

```bash
PERF_TRIALS=5 ./perf-harness-a.sh
```

Times 5 endpoints (`weld_run` list, per-run `weld_test_reports` × 1,000, batch
`weld_test_reports`, batch `weld_stats`, page-wide `weld_stats`) on both robots, 5 trials each
(trial 1 cold, 2–5 warm). Saves `results.json` + `novapi.log.slice` (NovApi's own per-request
timing log for that run) under `~/dev/scripts/novhub-local-stack/.state/perf-results/<UTC
timestamp>/`. Expected: every endpoint's `"baseline"` field says `"ok"` — any `"unavailable
(all calls failed)"` means something is broken (check MinIO/OpenSearch/NovApi are all up)
before trusting the numbers.

Copy that dated folder here, under `before-<timestamp>/` (or `after-<timestamp>/` once a fix
exists):

```bash
cp -r ~/dev/scripts/novhub-local-stack/.state/perf-results/<timestamp> \
  ~/dev/presentations/novhub-local-stack/hub106-perf-results/before-<timestamp>
```

Build (or hand-edit) a `report.html` in that same folder — see the existing
`important-reports/local-comparison-inputs/before-20261117T183701Z/report.html` as the
template: a log-scale bar chart of warm-median time per endpoint per robot, a headline
per-run-vs-batch comparison, and a full numbers table.

### Reading `novapi.log.slice` — the real server-side timing

This file is NovApi's own access log (morgan), one line per request, already showing a real
server-measured response time — independent of the harness's client-side wall-clock numbers,
which also include the HTTP round trip. One line looks like:

```
[2026-11-17T18:36:44.611Z] GET /api/v2/users/robots/910001/weld_run?page=1&per_page=2000 200  - 602.875 ms -  -
```

`[timestamp] METHOD PATH STATUS SIZE - RESPONSE_TIME ms -  -`. Turn it into a graphical report
with `perf-report.sh` (§3a below) instead of reading 20,000 lines by hand. From the current
Before run: `weld_run` (`per_page=2000`) took 603 ms server-side on its first (cold) call; the
10,000 per-run `weld_test_reports` calls had a 5.9 ms server-side median (18.2 ms slowest) —
confirming the ~1.4 s wall-clock number for that endpoint is mostly HTTP-round-trip/
connection-queueing overhead from firing 1,000 individual requests, not NovApi being slow to
answer any one of them.

## 3a. The graphical report tool

One tool, `perf-report.sh`, builds a zero-install `report.html` (open directly in a browser,
no server needed) from any combination of inputs — add more flags to get more sections in the
same report, nothing to re-run from scratch:

```bash
# NovApi server time only (per-endpoint table + chart, request timeline)
./perf-report.sh --novapi-log before-<ts>/novapi.log.slice --out before-<ts>

# Browser (HAR) time only (per-endpoint table, peak concurrency/staircase, timeline)
./perf-report.sh --har before-<ts>/weld-sessions.har --out before-<ts>

# Both together - adds a browser-vs-server comparison, matched by endpoint + closest
# start time (within 5s); the report states exactly how many matched and how many didn't
./perf-report.sh --novapi-log before-<ts>/novapi.log.slice --har before-<ts>/weld-sessions.har --out before-<ts>

# Add OpenSearch/Postgres slow-query logs for the same window (turn them on first,
# §3b) - adds a NovApi/OpenSearch/Postgres/Rest breakdown per endpoint
./perf-slowlog.sh on
# ... run the measurement ...
./perf-slowlog.sh off
./perf-report.sh --novapi-log before-<ts>/novapi.log.slice \
  --os-container os-local --pg-container cloud_db_dev --out before-<ts>

# A Chrome DevTools Performance recording (owner's manual "Save profile...", or §5's
# Playwright trace) - scripting time, longest task, long-task count, main-thread busy time,
# top JS functions by self time. ALWAYS scan it first (never prints the match, only where):
./trace-secret-scan.sh before-<ts>/analytics-performance.json
./perf-report.sh --trace before-<ts>/analytics-performance.json \
  --capture-metrics capture-<ts>/analytics-metrics.json --out before-<ts>
```

All forms write `report.html` + `data.json` into `--out` (use the same `before-<ts>`/
`after-<ts>` folder as everything else from that measurement — see §6). Running it again with
more flags against the same `--out` overwrites `report.html`/`data.json` with the combined
version, it doesn't create a second file.

**BEFORE vs AFTER:** the same tool, `--compare` instead of a plain run — see §7.

## 3b. Slow-query logging (optional, off by default)

```bash
./perf-slowlog.sh status   # current state, changes nothing
./perf-slowlog.sh on       # OpenSearch slowlog + Postgres log_min_duration_statement, both at 0ms/0 (log everything)
./perf-slowlog.sh off      # resets both - always do this once done measuring, the logs are noisy at this threshold
```

Local containers only (`os-local`, `cloud_db_dev`), idempotent, reversible, no NovApi code
change. For accurate per-request attribution in `perf-report.sh`'s breakdown, run the
measurement **sequentially** (concurrency 1) while this is on — concurrent requests' OpenSearch/
Postgres queries can't be told apart from each other reliably.

## 3c. Size sweep (no re-ingest)

The frozen dataset (§1) can't grow to real production scale locally (a heavy customer like
TAS has far more data than fits on this machine). Instead, sweep request size on the *same*
data to show how time grows with size:

```bash
./perf-sweep.sh
```

Times `weld_run` list at `per_page` 100/500/1000/2000, and both batch endpoints at batch size
100/250/500 (weld_test_reports/batch caps at 500 entries per call), all against the existing
1,000-runs-per-robot dataset. Save the output as `before-<ts>/size-sweep.json`.

## 4. Browser walkthrough (manual, with DevTools)

See [NETWORK_TAB_GUIDE.md](NETWORK_TAB_GUIDE.md) for how to open and read the Network tab,
written for a developer who hasn't used it much. Do this against the real local pages
(`http://localhost:5173`) with the dataset from §1 still in place:

- **Pages:** `WeldSessions`/`WeldInformation` (`/:robotName/analytics`), the `swr` variant of
  `WeldSessions` (same path, ready at `#tour-weld-sessions-table`), and `WeldQualityList`
  (`/:robotName/qc_report` — no DOM anchor, wait for network-idle on `weld_run` +
  `weld_test_reports` instead).
- Load each page for robot `PERF-ING-910001` (or `910002`), with DevTools open per the guide
  (cache disabled, log preserved), and record: how many requests fire, the waterfall shape
  (parallel vs. serial), total page load time, and which single request is slowest.
- Save a HAR export per page (`before-<timestamp>/<page-name>.har`) alongside the automated
  results — this is the human-driven counterpart to §3's automated numbers.

## 5. Automated page capture (Playwright)

Built. `perf-capture.sh` drives the real page with Playwright (NovAI build only — calls
`./brand-check.sh` first and fails loudly if either side isn't NovAI), dismisses the first-visit
"What's New in NovHub" tour modal, waits for the page to actually be usable, and saves a HAR, a
Performance trace, and a `*-metrics.json`. It then runs `perf-report.sh` on the HAR plus the
matching slice of NovApi's own log, into the same folder.

```bash
cd ~/dev/scripts/novhub-local-stack
./perf-capture.sh --page analytics --robot-name PERF-ING-910001 --out <dir>
./perf-capture.sh --page qc_report --robot-name PERF-ING-910001 --out <dir>   # same --out, same dated folder
```

- **Analytics** (`/:robotName/analytics`): clicks the first row to mount `WeldInformation` in
  detail view, so both the list-load and the row-click's own traffic are captured. "Usable" is
  **DOM-based**, not network-idle: `list_usable_ms` = the sessions table's QC-status badges
  filled and row count holding steady; `detail_usable_ms` = the same, measured from the click,
  for `WeldInformation`'s own table. Confirmed live against the real QC-status badge markup
  (`#tour-weld-sessions`/`#tour-weld-information`, `.ant-scroll-number.ant-badge-count`). The
  older `time_to_usable_ms` (network-idle: last matching request *starts*, + ~1200ms of no
  further matching requests) is kept as a secondary, labelled proxy — it tracks request
  *ordering*, not work volume, once a page makes only a handful of requests instead of hundreds,
  so prefer `list_usable_ms`/`detail_usable_ms` here.
- **QC Report** (`/:robotName/qc_report`): loads `weld_run` v2 plus `weld_test_reports/batch` —
  already batched, no row click in this tool. No QC-status badge column exists on this page
  (its "QC Report" column is a link, not a status badge), so `time_to_usable_ms` (network-idle)
  is its only usable signal — not a gap in the tool, there's no DOM signal to key off here.
- Request counts in `*-metrics.json` depend on the current NovApi/NovApp code — compare a real
  `before-<ts>`/`after-<ts>` pair (§7) rather than treating any one run's numbers as fixed.

Copy the dated folder here the same way as §3/§6 (`capture-<timestamp>/`), alongside the
`before-`/`after-` folders.

### One command for the whole AFTER set

`perf-after.sh` repeats everything above (brand + frozen-dataset check, endpoint baseline, size
sweep, both pages' Playwright capture) in one call, into one `after-<timestamp>` folder:

```bash
./perf-after.sh                                          # default --out: a new after-<ts> here
./perf-after.sh --har <owner's manual HAR> --trace <owner's manual trace>   # fold those in too, if already re-exported
```

## 6. Where results go

```
~/dev/presentations/novhub-local-stack/hub106-perf-results/
  README.md                 (this file)
  NETWORK_TAB_GUIDE.md
  before-<timestamp>/        (§3: results.json, novapi.log.slice, report.html; §4: *.har/trace, manual)
  after-<timestamp>/         (same shape - perf-after.sh builds this one in a single call, §5)
  capture-<timestamp>/       (§5: perf-capture.sh's own HAR/trace/metrics.json/report.html, one or more pages)
  before-vs-after-<timestamp>/  (§7: perf-report.sh --compare's report.html/data.json)
  important-reports/         (curated reports and the inputs needed to reproduce key results)
  historic/                  (superseded exploratory reports; retained, not deleted)
```

The curated reports are `important-reports/before-test-novai1555-20261118T200951Z/`
and `important-reports/before-vs-after-comprehensive-20261117T220824Z/`. The source
folders for the comprehensive local comparison are in
`important-reports/local-comparison-inputs/`. Exploratory one-off reports are kept in
`historic/`.

A `capture-<timestamp>/` folder predates `perf-after.sh` (its Playwright captures used to be run
standalone, before `perf-after.sh` folded them into `after-<timestamp>/`) — both shapes are
valid inputs to `perf-report.sh --compare`, pick whichever folder actually has the file you need.

A new measurement gets its own `before-`/`after-<timestamp>/` folder — never overwritten in
place, so a bad run doesn't erase a good one. (The one exception so far: the first
`before-20261117T180852Z` run was deleted and replaced after a real dataset bug was found and
fixed — see that folder's `report.html` fix-note for what changed and why.)

## 7. Comparing Before vs After

Once an `after-<timestamp>/` folder exists for the same dataset (§1, re-confirmed unchanged —
`perf-after.sh` checks this itself and refuses to run if it changed):

```bash
./perf-report.sh --compare --out before-vs-after-<ts> \
  --before-har-analytics before-<ts>/weld-sessions.har --after-har-analytics after-<ts>/weld-sessions.har \
  --before-novapi-analytics <matching log slice> --after-novapi-analytics <matching log slice> \
  --before-capture-analytics capture-<ts>/analytics-metrics.json \
  --after-capture-analytics after-<ts>/analytics-1/analytics-metrics.json --after-capture-analytics after-<ts>/analytics-2/analytics-metrics.json \
  --before-trace before-<ts>/analytics-performance.json --after-trace after-<ts>/analytics-performance.json
```

One `report.html`: API requests per endpoint (real + preflight), a dual waterfall of the first
2.5s on the same time axis, matched browser-vs-server time, main-thread scripting/longest
task/top functions from both traces, and Playwright medians+ranges (pass `--after-capture-*`
once per trial — repeatable). `--before-X`/`--after-X` are independent per item — see
`perf-report.sh --help` for the full list (`analytics`/`qc` x har/novapi-log/capture, plus
trace). Anything present on only one side is listed in the report as not yet comparable, never
silently dropped or guessed at.

A real fix should show up consistently: fewer/faster requests in the HAR, a smaller matched
browser/server gap, less scripting time, and (for Analytics) a real drop in
`list_usable_ms`/`detail_usable_ms` — not just the network-idle proxy, which reacts to request
*ordering* as much as to work done and can rise even when the real page is faster.
