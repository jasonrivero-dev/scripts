# HUB-106 results: Analytics page load, robot NovAI-1555

## What was tested

- **Site:** dev-novhub.novarctech.com
- **Robot:** NovAI-1555, the same robot for both runs. No records were added between them.
- **Page:** Analytics
- **Before:** the old code, which sent one request per weld run (captured 20 Nov)
- **After:** the deployed fix, which sends one request per 500 weld runs (captured 24 Nov)
- **Method:** Chrome DevTools capture of the page load, same method for both

## Result

| | Before | After | Change |
|---|---|---|---|
| Requests to open the page | 2,191 | 26 | 99% fewer |
| Report requests | 2,152, one per run | 5, up to 500 runs each | 430× fewer |
| Typical report request | 4.5 s | 0.13 s | 35× faster |
| Slowest report request | 19.8 s | 0.16 s | 120× faster |
| Time to load all report data | 19.9 s | 0.7 s | 28× faster |
| Browser main-thread busy time | 7.1 s | 3.6 s | 50% less |
| Longest single browser freeze | 1.3 s | 0.4 s | 69% less |

## What it means

- The page used to ask the server for each weld run separately: 2,152 requests. It now asks for 500 runs at a time: 5 requests covering 2,131 runs.
- All the report data loads in under 1 second, down from about 20.
- The browser also does less work: less busy time and shorter freezes.

## Notes

- The robot holds 2,260 runs in total. The after capture asked for 2,131 of them (batches of 500, 500, 500, 500 and 131). The before figure of 2,152 counts requests, one per run; its run list was not read from the request contents.
- The before capture includes five `weld_stats` requests (13.7 s each) from the Machine Operation Trends widget. The after capture has none, so the widget was not loaded in that run. For this reason the table compares report requests only, and leaves out the time to load the whole page.
- The date windows differ between the captures. Both load the default last-30-days windows (before ending 20 Nov, after ending 24 Nov). The after capture also includes a custom 11 to 20 Nov range.
- The measurements cover data loading and browser work. They are not a single page-load time.

## Sources

- Before: `dev-novai1555-20261120T174209Z/reports/before/report.html`
- After: `dev-novai1555-20261124T211014Z/reports/after/report.html`
