# HUB-106 BEFORE/AFTER Performance Runbook

Measures the NovHub Analytics page for robot NovAI-1555 (2,260 runs on dev) before and after the HUB-106 change, and builds one combined report.

- Main procedure (sections 1 to 9): **manual Chrome DevTools** capture, standard file names.
- Appendix A: the automated Playwright capture. It currently fails on the dev site (see [HUB-106-HANDOFF.md](./HUB-106-HANDOFF.md)); use it only once that is fixed.
- Dev data setup (login, tunnel, ingest of the 2,260 runs) is in [HUB-106-DEV-INGEST-AND-PERFORMANCE-RUNBOOK.md](./HUB-106-DEV-INGEST-AND-PERFORMANCE-RUNBOOK.md), steps 1 to 6.

## Important existing reports

The curated reports are under
[important-reports/](./hub106-perf-results/important-reports/):

- [Prior cloud BEFORE baseline](./hub106-perf-results/important-reports/before-test-novai1555-20261118T200951Z/report.html)
- [Prior comprehensive local BEFORE/AFTER report](./hub106-perf-results/important-reports/before-vs-after-comprehensive-20261117T220824Z/report.html)

The actual path to the comprehensive report is under
`presentations/novhub-local-stack/hub106-perf-results/`; the earlier path without
`novhub-local-stack/` does not exist. Its local comparison inputs are retained in
`important-reports/local-comparison-inputs/`. Superseded exploratory outputs are
retained in `hub106-perf-results/historic/`.

## What is compared

- BEFORE: dev site with the old code. Capture it while dev still runs the old code.
- AFTER: the branch code. Same steps; only the page address differs. A local NovApi and NovApp against the dev data needs the cloud launcher, which does not exist yet (HUB-106-HANDOFF.md, "Launcher and capture target"). If the PR is merged later and dev redeploys, AFTER can use the dev site instead.
- Both sides must use the **same underlying robot data** (NovAI-1555, robot ID `1555`) and the same settings below. If the data or the settings differ, stop; the comparison will not justify a code-only conclusion.

## Fixed settings (identical for BEFORE and AFTER; never change between them)

| Setting | Value |
|---|---|
| Page | Analytics for robot NovAI-1555 |
| Date range | 2024-10-01 to 2026-11-30 |
| Chrome | Same Chrome, no extensions, Disable cache ticked, throttling "No throttling" |
| Recording | One recording per side, no page reload during it |
| Login | Your own dev login, signed in and the "What's New" dialog dismissed before recording |

## Standard output layout (the report commands depend on these exact names)

```text
hub106-perf-results/dev-novai1555-<UTC timestamp>/
  before/
    analytics.har                 HAR from the Network tab (sanitized)
    analytics-performance.json    raw trace JSON from the Performance tab
    notes.txt                     page address, date range, commit or build, time
  after/
    analytics.har
    analytics-performance.json
    notes.txt
  reports/
    before/report.html
    after/report.html
    before-vs-after/report.html
```

Appendix A adds `before-1` to `before-5` and `after-1` to `after-5` folders in the same run folder.

## 0. Preconditions (check before BEFORE)

| Check | Command | Expected | If different |
|---|---|---|---|
| Robot has all runs | `cd ~/dev/scripts/novhub-local-stack && ./perf-rank-robots.sh --target dev --robot-id 1555` | `2260` | Stop; ingest runbook steps 1 to 6 |
| PR not merged | `git -C ~/dev/novhub fetch -q && git -C ~/dev/novhub branch -r --contains 8d829b4` and `git -C ~/dev/NovApi branch -r --contains 90a99dd` | Only `origin/jaguar/HUB-4.2.0-release-prep` listed; no `origin/main` | PR already merged: dev may run the new code, so BEFORE is invalid; ask the lead which dev build is deployed |
| Capture config (Appendix A only) | `cat perf-targets.dev.env` | `PERF_ROBOT_NAME=NovAI-1555`, `PERF_RANGE_START=2024-10-01`, `PERF_RANGE_END=2026-11-30`, dev URLs | Fix the file; never change the range between BEFORE and AFTER |
| Login secret (Appendix A only) | `ls -l .state/secrets/perf-test-user-dev.secret` | mode `-rw-------` | `chmod 600` it |
| Playwright installed (Appendix A only) | `./perf-setup.sh` | `already ...` or `created` | Run it |

BEFORE is valid only while dev runs the old code.

## 1. Create the folder (once, for BEFORE and AFTER)

```bash
cd ~/dev/scripts/novhub-local-stack
RESULTS="$HOME/dev/presentations/novhub-local-stack/hub106-perf-results"
RUN_DIR="$RESULTS/dev-novai1555-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_DIR/before" "$RUN_DIR/after" "$RUN_DIR/reports"
echo "$RUN_DIR"
```

Expected: it prints the new folder path. Write it down. In a new terminal, restore it with:

```bash
RESULTS="$HOME/dev/presentations/novhub-local-stack/hub106-perf-results"
RUN_DIR="$(ls -d "$RESULTS"/dev-novai1555-* | tail -1)"; echo "$RUN_DIR"; ls "$RUN_DIR"
```

Expected: the folder with `before`, `after` and `reports`.

## 2. Capture BEFORE (deployed dev, old code)

1. Open Chrome, go to `https://dev-novhub.novarctech.com`, sign in, open Analytics for NovAI-1555. If the "What's New" dialog appears, click Skip. Wait until the page stops loading.
2. Press F12. Network tab: tick **Disable cache**, tick **Preserve log**, click the clear button (circle with a line).
3. Performance tab: click Record (the circle). Do **not** use the reload-and-record button; it resets the date range to the last 7 days.
4. On the page, change the date range to 2024-10-01 to 2026-11-30 (start date, end date, Enter). The page loads all the robot's runs.
5. Wait until the table and the QC status column stop changing. With old code this can take 30 seconds or more, and some calls fail; that is expected.
6. Click Stop in the Performance tab.
7. Save the trace: Performance tab, the down-arrow "Save profile" icon; save as `analytics-performance.json` into `$RUN_DIR/before/`.
8. Save the HAR: Network tab, the down-arrow "Export HAR" icon, choose "Save all as HAR with sanitized content" (this drops cookies and Authorization headers); save as `analytics.har` into `$RUN_DIR/before/`.
9. Write the notes file:

```bash
printf 'page: https://dev-novhub.novarctech.com/NovAI-1555/analytics\nrange: 2024-10-01 to 2026-11-30\ncode: old (dev before merge)\ncaptured: %s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/before/notes.txt"
cat "$RUN_DIR/before/notes.txt"
```

`notes.txt` is created by you, by this command; no tool generates it and no script reads it (the reports do not use it). It is a record for reproducing the result later. Expected content of `cat`:

```text
page: https://dev-novhub.novarctech.com/NovAI-1555/analytics
range: 2024-10-01 to 2026-11-30
code: old (dev before merge)
captured: 2026-11-20T18:05:12Z
```

## 3. Verify BEFORE

```bash
cd ~/dev/scripts/novhub-local-stack
ls -l "$RUN_DIR/before"
./trace-secret-scan.sh "$RUN_DIR/before/analytics-performance.json"
H="$RUN_DIR/before/analytics.har"
echo "per-run GET weld_test_reports: $(jq '[.log.entries[]|select(.request.method=="GET" and (.request.url|test("/weld_test_reports(\\?|$)")))]|length' "$H")"
echo "batch POST weld_test_reports/batch: $(jq '[.log.entries[]|select(.request.method=="POST" and (.request.url|test("/weld_test_reports/batch")))]|length' "$H")"
echo "Authorization/Cookie headers: $(jq '[.log.entries[]|.request.headers[]|select(.name|test("(?i)^(authorization|cookie)$"))]|length' "$H")"
```

Expected: three files listed; the scan reports no token or cookie; per-run GET in the thousands (the test environment gave 3,195); batch POST `0`; header count `0`. If the scan flags the trace, do not use or share it: record again. If batch POST is above 0, dev already has the new code: it is not a BEFORE. If per-run GET is 0, the range change was not captured: record again.

## 4. BEFORE report (single side)

```bash
./perf-report.sh --har "$RUN_DIR/before/analytics.har" --trace "$RUN_DIR/before/analytics-performance.json" --out "$RUN_DIR/reports/before"
```

Expected: it prints `report: .../reports/before/report.html`. Open it in a browser.

## 5. Capture AFTER

Same steps as section 2, with these differences only: the page address is the one serving the branch code (local NovApp, or the dev site after a merge and redeploy), files go in `$RUN_DIR/after/` with the same names, and `notes.txt` records the code and address used (NovApi and NovApp commit).

```bash
printf 'page: <the address you used>\nrange: 2024-10-01 to 2026-11-30\ncode: <branch commit or deployed build>\ncaptured: %s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/after/notes.txt"
```

Replace the two `<...>` texts with real values first; an unedited command writes the placeholder text into the notes. Like the BEFORE file, it is created by you and read by no tool. Sample of a finished AFTER file (the commit values come from `git -C ~/dev/NovApi rev-parse --short HEAD` and `git -C ~/dev/novhub rev-parse --short HEAD`; the values below are only an example):

```text
page: http://localhost:5173/NovAI-1555/analytics
range: 2024-10-01 to 2026-11-30
code: branch jaguar/HUB-4.2.0-release-prep, NovApi 0c64cba, NovApp 8d829b4, run locally against dev data
captured: 2026-11-20T19:40:03Z
```

## 6. Verify AFTER and its report

Same block as section 3 with `before` replaced by `after`. Expected: scan clean; per-run GET `0`; batch POST about `5` (2,258 runs in chunks of 500); header count `0`. If per-run calls remain, the page is not running the new code.

```bash
./perf-report.sh --har "$RUN_DIR/after/analytics.har" --trace "$RUN_DIR/after/analytics-performance.json" --out "$RUN_DIR/reports/after"
```

## 7. One combined report

```bash
./perf-report.sh --compare --out "$RUN_DIR/reports/before-vs-after" \
  --before-har-analytics "$RUN_DIR/before/analytics.har" \
  --after-har-analytics "$RUN_DIR/after/analytics.har" \
  --before-trace "$RUN_DIR/before/analytics-performance.json" \
  --after-trace "$RUN_DIR/after/analytics-performance.json"
```

Expected: it prints `report: .../reports/before-vs-after/report.html` and `data:`. Open the report. In compare mode use the `--before-*` and `--after-*` flags; plain `--har` and `--trace` are for a single side. Trace files must be raw Chrome DevTools JSON; Playwright's `analytics-trace.zip` is not accepted.

## 8. What the result can say

- Request counts compare fully (per-run calls to batch calls).
- Seconds compare only when both sides run the same way. A local NovApi (HTTP/1.1, tunnel to dev data) and the deployed dev site (Cloudflare, HTTP/2) give different seconds for the same code. For a fair seconds comparison, also record `main` on the same local setup (same steps, files into a `before-local/` folder with the same names) and compare that against `after/`.
- One recording per side is one sample, not proof; state that.
- Robot 1555 mixes 129 real runs with 2,131 synthetic ones.

## 9. Keep the evidence together, then clean up

Keep the raw HARs, the scanned raw traces, the notes files, the single-side reports and the comparison report in `$RUN_DIR`. `notes.txt` records the exact range, address and code so the results can be reproduced.

If the tunnel and hosts line are open:

```bash
cd ~/dev/scripts/novhub-local-stack
./cloud-hosts.sh remove --env dev && ./cloud-tunnel.sh close --env dev
ps aux | grep '[c]loud-tunnel-dev'
```

Expected: nothing printed by the last command. Removing the synthetic data from dev (`./cloud-ingest.sh --env dev --remove --confirm-delete`) is optional.

## Appendix A. Automated capture (five trials per side)

Currently fails on the dev site: the page never gets API data (`net::ERR_FAILED`); diagnosis and next steps are in HUB-106-HANDOFF.md. Use only once a single trial passes the check below.

Per side, run five trials into one fixed run folder (set `RUN_DIR` as in section 1). An existing trial folder is skipped, never overwritten; the loop stops at the first failure:

```bash
cd ~/dev/scripts/novhub-local-stack
for i in 1 2 3 4 5; do
  if [ -d "$RUN_DIR/before-$i" ]; then echo "already: before-$i"; continue; fi
  ./perf-capture.sh --target dev --page analytics --out "$RUN_DIR/before-$i" || break
done
```

Each trial creates `analytics.har`, `analytics-metrics.json`, `analytics-trace.zip`, `report.html`, `data.json`. Verify each (BEFORE expects `weld_test_reports` in the thousands, no `weld_test_reports_batch`, `applied: true`, numbers in both usable fields; AFTER expects about 5 `weld_test_reports_batch` and no per-run `weld_test_reports`):

```bash
for i in 1 2 3 4 5; do jq -c '{trial: "before-'$i'", date_range_used, list_usable_ms, detail_usable_ms, request_counts}' "$RUN_DIR/before-$i/analytics-metrics.json"; done
```

For AFTER, run one trial first (`after-1`) and check it before the other four; if per-run calls remain, the page is not running the new code, so remove only that trial folder and capture again later. Then:

```bash
for i in 2 3 4 5; do
  if [ -d "$RUN_DIR/after-$i" ]; then echo "already: after-$i"; continue; fi
  ./perf-capture.sh --target dev --page analytics --out "$RUN_DIR/after-$i" || break
done
```

Combined report from the trials (HAR of trial 1 per side, metrics of all five):

```bash
./perf-report.sh --compare --out "$RUN_DIR/reports/before-vs-after-trials" \
  --before-har-analytics "$RUN_DIR/before-1/analytics.har" \
  --after-har-analytics "$RUN_DIR/after-1/analytics.har" \
  --before-capture-analytics "$RUN_DIR/before-1/analytics-metrics.json" \
  --before-capture-analytics "$RUN_DIR/before-2/analytics-metrics.json" \
  --before-capture-analytics "$RUN_DIR/before-3/analytics-metrics.json" \
  --before-capture-analytics "$RUN_DIR/before-4/analytics-metrics.json" \
  --before-capture-analytics "$RUN_DIR/before-5/analytics-metrics.json" \
  --after-capture-analytics "$RUN_DIR/after-1/analytics-metrics.json" \
  --after-capture-analytics "$RUN_DIR/after-2/analytics-metrics.json" \
  --after-capture-analytics "$RUN_DIR/after-3/analytics-metrics.json" \
  --after-capture-analytics "$RUN_DIR/after-4/analytics-metrics.json" \
  --after-capture-analytics "$RUN_DIR/after-5/analytics-metrics.json"
```

Expected: it prints `report:` and `data:` paths. Manual (DevTools) and automated (Playwright) numbers are different methods; do not mix them in one timing comparison.
