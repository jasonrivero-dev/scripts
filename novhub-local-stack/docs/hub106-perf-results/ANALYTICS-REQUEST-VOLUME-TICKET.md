# Ticket draft: Analytics page sends far more requests than it needs, and large requests fail

Assignee: jason.rivero@novarctech.com
Related: HUB-106 (batching of weld test reports, already merged), HUB-33 (origin of the `weld_stats/batch` endpoint)
Repositories: NovApp (cause), NovApi (missing limits)

## Summary

On the Analytics page the browser asks the server for the same data several times, and it sends each run's statistics three times over. For robots with many weld runs, the largest statistics requests fail with HTTP 500, so the Machine Operation Trends widget gets no statistics. The causes are in code older than HUB-106. They show up only at volume.

## What happens, in plain terms

1. The page loads weld runs in pages of 2,000. That part works: each page is requested once.
2. After every page, the page asks the server for statistics on all runs loaded so far, not only the new page. With 7,657 runs it asks for 2,000, then 4,000, then 6,000, then 7,657. The same runs are sent again each time. In the capture, 44,525 run IDs were sent for 15,067 distinct runs, about three times the work.
3. The statistics request does not wait for the run list to finish loading. It is skipped only when the list is empty. Each new page therefore starts a new request.
4. The server does not limit how many run IDs one statistics request can carry, and it starts all its searches at once. Requests of 3,458 IDs or fewer succeeded. All six requests of 4,000 IDs or more failed with 500 after 6 to 10 seconds. Nothing between 3,459 and 3,999 was tested.
5. The page fetches the same date windows more than once. Two components fetch the 11 to 25 Nov window at the same moment. About 4.2 seconds later the whole set of first-page requests repeats, because the main widget is replaced by a loading placeholder while the run list loads and is built again once the last page arrives. Every widget then starts over from page 1.
6. The code asks for a forced refetch, so a repeated request goes to the server instead of being answered from the cache.
7. The same pattern exists in seven places that ask for statistics (see Scope). A second batch endpoint, `weld_config_associations/batch`, also sends the whole list again each time it grows.

## Evidence

Capture: dev-novhub, robot NovAI-1555, Analytics page, 25 Nov 2026, Chrome DevTools HAR and performance trace, browser cache disabled. The robot held 20,129 runs. The page loads two 30-day windows, 7,410 and 7,657 runs.

| Measure | Value |
|---|---|
| Requests in the page load | 43 |
| `weld_stats/batch` requests | 10, of which 4 returned 200 (2,000 to 3,458 IDs) and 6 returned 500 (4,000 to 7,657 IDs) |
| Run IDs sent to `weld_stats/batch` | 44,525, for 15,067 distinct runs |
| Repeated first-page `weld_run` requests | 7 in the second wave, plus 1 duplicate inside the first wave |
| Time for the page to settle | 24.6 s (a proxy figure from the report tool, not an explicit render mark) |

The weld test report requests added in HUB-106 are not part of the problem. They send up to 500 runs per request, and each of the 7 requests in this capture answered in about 0.17 s.

## Causes

NovApp (all confirmed in code at origin/main 4223854; commit history shows both predate HUB-106):

- `src/services/api/robot.ts:1327-1344` sets the accumulated list after every page (commit bb5a9bd7, 9 Jul 2026).
- `src/components/widget/MachineOperationTrends.tsx:274-282` and `:772-775` request statistics for the growing list, with no loading guard (commit 947f3e60, 14 May 2026, for the first).
- `MachineOperationTrends.tsx:779` replaces the subtree with a loading placeholder while `useRobotsWithWeldRuns` reports loading. The flag comes from `robot.ts:1314, 1328, 1357-1360`. The subtree is built again when the last page arrives, which causes the second wave.
- `robot.ts:1337` calls the lazy trigger without `preferCacheValue`, so every call forces a refetch.
- `MachineOperationTrends.tsx:380-387` fetches the top-level window a second time on its own, because the shared data lacks the arc on and off fields.

NovApi (read in code, not yet confirmed by the server log):

- `routes/api/v2/users.js:679` accepts any non-empty array of run IDs for `weld_stats/batch`. `getBatchWeldStatsPerRun` splits the IDs into chunks of 50 and starts all chunks at once (80 searches at 4,000 IDs, 154 at 7,657).
- `weld_config_associations/batch` (`users.js:2324`) has no ID limit either. `weld_test_reports/batch` already limits a request to 500.

## Scope

Seven places ask for statistics with an unbounded, growing list: `MachineOperationTrends.tsx` (two sites), `WeldSessions.tsx:220`, `QualityTrendsStatistics.tsx:113`, `WeldQualityTrendsList.tsx:364`, `ProcessWindowMonitoring.tsx:522` and `:962`.

Any limit on the server affects all seven, and any other caller that sends more IDs than the limit.

## Proposed phases (the split is the owner's decision)

Phase 1, NovApp: stop the repeated and cumulative requests.
- Request statistics once per date range, after the run list is complete.
- Split the list into requests no larger than the limit chosen in Phase 2.
- Send each run to `weld_config_associations/batch` once.
- Keep the widgets mounted while the run list loads, and let the performance card share the page's data.

Phase 2, NovApi: bound the endpoints.
- A maximum number of run IDs for `weld_stats/batch` and `weld_config_associations/batch`, enforced with a 400, defined once as a named constant.
- A small fixed concurrency for the 50-run chunks in `weld_stats/batch`.
- Remove duplicate IDs. Log the ID count with an error.
- Optionally a date-range limit on `weld_run` and `downtime`.

Phase 3: confirm the cause of the 500s and measure.
- Read the OpenSearch error line for the first failed request.
- Repeat the capture with the cache on.

## Acceptance (outcomes)

- On robot 1555 with the default windows and at least 20,000 runs in the last 60 days, no `weld_stats/batch` request returns 500.
- Each run's statistics are requested once per date range.
- No request carries more run IDs than the limit.
- The first-page `weld_run` request for a window is sent once per page load.
- Verified with the same method as HUB-106: Chrome DevTools capture, request counts compared with this capture.

## Open items

- The OpenSearch log line for the 500s. NovApi's best reading, unconfirmed, is that starting all searches at once overloads OpenSearch.
- The size between 3,459 and 3,999 IDs where requests start to fail.
- Why the performance card's own fetch fires in the first wave and not the second (a timing race in RTK Query's duplicate check, not verified).
- All findings come from static code and one capture. The rebuild of the subtree was not reproduced in a live page.

## Not in this ticket

- The report batches from HUB-106.
- The migration moved to HUB-118 and the PostgreSQL test harness in HUB-117.
