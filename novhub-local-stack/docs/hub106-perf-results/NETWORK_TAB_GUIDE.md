# Browser DevTools for HUB-106 (written for a C++ developer, not a web dev)

You already know how to read a profiler trace or an strace log. The browser's Network tab is
the same idea, scoped to one page load: every HTTP request the page made, when it started,
how long it took, and how big the response was. The Performance tab is the equivalent for
"where did the CPU time go in JS/rendering," closer to a flame graph.

## Opening it

1. Load the page first (`http://localhost:5173/<robot>/analytics`), **then** open DevTools
   (`F12` or `Ctrl+Shift+I`), click the **Network** tab, and reload the page (`Ctrl+R`) with
   DevTools already open — Network only records requests made while it's open.
2. Three checkboxes matter, all near the top of the Network panel:
   - **Disable cache** — on, always. Otherwise a second load looks artificially fast because
     the browser skipped the network entirely, the same way a warm filesystem cache skips disk.
   - **Preserve log** — on, if you're going to navigate between pages and still want the
     earlier requests visible (otherwise the log clears on navigation, like a ring buffer that
     resets).
   - **Throttling** — leave as "No throttling" for this work; we're measuring local backend
     cost, not simulating a slow network. (It exists for the opposite case — faking a slow
     connection — not relevant here.)

## What you're looking at: the waterfall

Each row is one HTTP request. The horizontal bar is time, left edge = when it started, right
edge = when it finished — literally a Gantt chart. For the pages in this ticket, what you want
to see is whether the per-run requests (`weld_test_reports?run_id=...`, one per weld run) are:

- **Stacked in a staircase, 6 bars wide at a time** — this is the current, known-slow pattern:
  the browser only runs 6 requests at once per host (HTTP/1.1's per-host connection limit), so
  1,000 of these requests queue up 6-at-a-time, each batch waiting for the previous one.
- **Or one single bar** for a batch call — the fast path, same data, one request.

## Columns that matter

Click a request to expand it; the **Timing** tab inside that detail view breaks one request
down the way a profiler breaks down one function call:

- **Waiting (TTFB — Time To First Byte)**: time from "request sent" to "first byte of the
  response arrived." This is almost entirely server-side cost — the equivalent of how long
  your own function took to run before it started writing output. If this number is high,
  the slowness is in NovApi/Postgres/OpenSearch, not in the browser.
- **Content Download**: time to pull the rest of the response body over the wire. Usually tiny
  on localhost; matters more for large payloads.
- **Size** column (in the main table, not the detail view): response body size. A single
  `weld_run` list call with a big `per_page` can be large; individual `weld_test_reports` calls
  are small.

## Exporting a HAR (exact steps)

Current Chrome (verified against the DevTools source change that introduced this — commit
"Export sanitized HARs by default", Sep 2024 — not against Chrome's own published docs, which
don't describe the export UI in this much detail) moved HAR export off the right-click menu and
onto a dedicated toolbar icon. The right-click menu (Open in Sources/new tab, Copy, Block,
Throttle, Sort, Override, Debug with AI) is for one request at a time, not the whole capture.

1. Load the page, with DevTools' Network tab already open and "Disable cache" checked (see
   above) — don't open DevTools after the page has already loaded, you'd miss the requests.
2. Let the page fully settle (no new requests for a second or two).
3. In the Network panel's own toolbar (the row of icons above the request list, next to the
   clear-log and filter icons), click the **export/down-arrow icon**. It opens a small menu with
   two entries: **Export HAR (sanitized)** and **Export HAR (with sensitive data)**.
4. **Use "Export HAR (sanitized)"** — it's what you want by default, and keeps every timing
   field (Waiting/TTFB, Content Download, start offsets) intact. It leaves out the `Cookie`,
   `Set-Cookie`, and `Authorization` headers specifically, so the JWT this app sends on every
   request is never written to disk. "Export HAR (with sensitive data)" keeps that header too —
   only use it if you specifically need to inspect the auth header itself, and only on local
   test data (never TAS's own captured traffic). That option is **hidden until you turn it on**:
   DevTools' gear icon (top right of the DevTools dock, or press `F1`) → **Preferences** →
   **Network** → tick **"Allow to generate HAR (with sensitive data)"**. It's off by default on
   purpose — leave it off unless you have a specific reason to turn it on.
5. Save it as `<page-name>.har` into today's dated results folder, e.g.
   `~/dev/presentations/novhub-local-stack/hub106-perf-results/before-<timestamp>/weld-sessions.har`
   (create that folder first if it doesn't exist yet for this walkthrough).

### Optional: DevTools' own "Debug with AI" as a second opinion

The right-click menu on a single request also has a **Debug with AI** submenu (Start a chat,
Explain purpose, Explain slowness, Explain failures, Assess security headers). This is Chrome's
own built-in assistant (Gemini) — picking any of these **sends that request's data to Google**,
not to this tooling. It's fine to use it as a second opinion on one specific request you're
already looking at (e.g. "Explain slowness" on the slowest `weld_test_reports` call) — your
call, and only on local test data, never on anything from a real customer capture.

### Preflight (CORS OPTIONS) requests

Roughly half the rows in an Analytics-page HAR are `OPTIONS` preflights, not real requests: the
browser sends one automatically before each cross-origin `GET`/`POST` with an `Authorization`
header (NovApp on `:5173` calling NovApi on `:3000` is cross-origin), and the server answers it
in well under 1ms before the real request even starts — see `novapi.log.slice`, which logs these
too (`OPTIONS ... 204 ... - 0.05 ms`). `perf-report.sh` now counts and reports these separately
from real requests (a "real vs. preflight" split in the HAR summary line, and a per-endpoint
"Preflights" column) instead of lumping them into one request count.

A HAR file is a JSON dump of every request/response/timing pair from that page load — think of
it as a trace file you can hand to someone else or diff later, the same way you'd save a `perf
record` output. Once saved, turn it into the same kind of table/chart the automated reports
use:

```bash
./perf-report.sh --har <path-to-the.har> --out <dated-folder>
```

(run from `~/dev/scripts/novhub-local-stack`) — builds `<dated-folder>/report.html`: request
count, peak concurrency (whether requests formed a staircase or ran one at a time), and a
per-endpoint table of browser time. This works on *any* HAR — the owner's manual browser export
or one Playwright produces — so both are directly comparable in the same report. Add
`--novapi-log <path>` to the same command to also show server-side time and a browser-vs-server
comparison, matched by endpoint + time (see the main README's "Reading `novapi.log.slice`"
section).

## The Performance tab (JS/render cost, not network)

If the Network tab shows requests finishing reasonably fast but the page still *feels* slow,
the cost may be in JavaScript execution or rendering (e.g., re-rendering a huge table row by
row), not the network. The **Performance** tab records exactly that:

1. Click **Performance**, click the record button (●), reload or interact with the page, then
   stop recording.
2. You get a flame graph (same concept as any sampling profiler's flame graph) with a "Main"
   thread track showing JS function calls stacked by caller, and a summary pie chart (Scripting
   / Rendering / Painting / Idle).
3. Long yellow (Scripting) bars = slow JS. Long purple (Rendering) bars = the DOM/layout cost
   of rendering what came back from the network — relevant if a page renders a very large
   table of weld-run rows at once.
4. **Save the profile:** after stopping the recording, click the down-arrow/save icon in the
   Performance panel's toolbar (top-left area, next to the record button) → saves a `.json`
   trace file. Save it as `<page-name>-performance.json` into the same dated results folder as
   the HAR above. To reload one later: open the Performance tab, click the up-arrow/load icon,
   pick the file.
5. In the summary pie chart (or the "Bottom-Up"/"Call Tree" tabs below the flame graph), note
   the total Scripting time and the single longest task — those are the two numbers worth
   writing down alongside the HAR's request count/total time.

## Quick checklist for this ticket

- [ ] Disable cache: on
- [ ] Reload with DevTools already open
- [ ] Note request count and waterfall shape for the per-run pattern (staircase of 6s) vs. any
      batch call (single bar)
- [ ] Check Waiting (TTFB) on the slowest request — server-side or network-side?
- [ ] Export HAR, save next to the automated results for that run
- [ ] If the page still feels slow with network reasonably fast, repeat with the Performance
      tab and look for long Scripting/Rendering bars
