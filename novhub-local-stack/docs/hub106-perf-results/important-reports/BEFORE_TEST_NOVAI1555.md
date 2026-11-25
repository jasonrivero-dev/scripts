# HUB-106 BEFORE: test-novhub, robot NovAI-1555, Analytics page

Captured by the owner in Chrome DevTools (one recording, Disable cache on, no reload): the date range was changed from the default week to 2024-10-01 → 2026-11-18, which loads all of the robot's runs (2,258 distinct run IDs). Test runs the deployed code from before our change. Files: `before-test-novai1555-20261118T200951Z/` (`report.html`, `data.json`, HAR, trace). Both files were scanned: no token or cookie in the trace; no Authorization or cookie headers in the HAR.

## Requests after the range change (burst of 27.4 s)

| Request | Count | OK (200) | HTTP 500 | No response | Median | 95th percentile |
|---|---|---|---|---|---|---|
| GET weld_test_reports (one per run) | 3,195 | 733 | 740 | 1,722 | 1.7 s | 16.4 s |
| GET weld_run | 16 | 16 | 0 | 0 | 2.9 s | 16.7 s |
| GET downtime | 6 | 3 | 0 | 3 | 0.8 s | 16.8 s |
| POST weld_stats/batch | 4 | 1 | 0 | 3 | 1.2 s | 1.2 s |
| POST weld_config_associations/batch | 2 | 0 | 0 | 2 | 1.5 s | 1.2 s |

Each GET and POST above also had its own preflight (OPTIONS). The run IDs behind the 3,195 per-run calls are 2,258 distinct, so about 940 are repeats.

## What the numbers show

- The page fired the per-run calls with up to 2,258 in flight at once. Only 733 of 3,195 succeeded.
- The same small `weld_run` windows (41-byte answers) took about 0.4 s before the flood and about 16.6 s after it started. The flood delays unrelated calls.
- Three of four `weld_stats/batch` calls and both `weld_config_associations/batch` calls failed during the flood.
- The wide `weld_run` list itself: 3.6 s and 2.3 s for 3.1 MB (first 2,000 runs), 0.6 s for the next 0.4 MB page.
- Browser: 3.0 s scripting, longest task 1.0 s, 5 long tasks (over 50 ms), 9.6 s main thread busy. The render-settle proxy is 6.3 s after the last test-report call (a proxy, not a render mark).

## Not known

- Why calls failed. The 500s are server errors. The no-response calls could be a Cloudflare limit, a connection limit at the server, or the browser cancelling; the HAR does not say.
- Why about 940 run IDs were requested more than once.
- Noise: one recording only. Repeat it before quoting small differences.

## Expected AFTER with our change (to check, not a result)

About 5 `weld_test_reports/batch` POSTs (2,258 runs in chunks of 500), no per-run calls, no flood.
