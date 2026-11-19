#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  cat <<USAGE
Usage: perf-report.sh --out <dir> [--novapi-log <path>] [--har <path>]
                       [--trace <path>] [--capture-metrics <path>]
                       [--os-container <name> --pg-container <name>]

HUB-106: ONE zero-install graphical report (report.html, open directly in a
browser) from any combination of inputs:

  --novapi-log <path>   NovApi's own request log (server time per request)
  --har <path>           a HAR file - the owner's browser export or
                          Playwright's (browser time per request)
  --trace <path>         a Chrome DevTools Performance recording ("Save
                          profile...", raw trace JSON) - total scripting
                          time, longest task, long task count (>50ms),
                          main-thread busy time, top JS functions by self
                          time. Run trace-secret-scan.sh on it FIRST, before
                          sharing it anywhere - this flag does not check for
                          leaked tokens/cookies.
  --capture-metrics <path>
                          a *-metrics.json from perf-capture.js - shown next
                          to --trace's numbers for direct comparison
  --os-container / --pg-container
                          OpenSearch/Postgres slow-log containers for the
                          same window (turn them on first: perf-slowlog.sh
                          on) - adds a NovApi/OpenSearch/Postgres/Rest
                          breakdown per endpoint. Only meaningful together
                          with --novapi-log.

Given --novapi-log and --har together, matches requests by endpoint +
closest start time (within 5s) and adds a browser-vs-server comparison -
the report states exactly how many matched and how many didn't.

Examples:
  perf-report.sh --novapi-log before-<ts>/novapi.log.slice --out before-<ts>
  perf-report.sh --har before-<ts>/weld-sessions.har --out before-<ts>
  perf-report.sh --novapi-log before-<ts>/novapi.log.slice --har before-<ts>/weld-sessions.har --out before-<ts>
  perf-report.sh --novapi-log before-<ts>/novapi.log.slice --os-container os-local --pg-container cloud_db_dev --out before-<ts>
  perf-report.sh --trace before-<ts>/analytics-performance.json --capture-metrics capture-<ts>/analytics-metrics.json --out before-<ts>

--compare: a BEFORE-vs-AFTER report instead of a single run. Same tool, not
a second one - pass --before-X/--after-X pairs instead of the plain flags
above (--before-har-analytics, --before-novapi-analytics,
--before-capture-analytics [repeatable, one per trial], --before-trace, and
the same four for "qc" and every "after-" counterpart). Anything present on
only one side is listed in the report as not yet comparable. Full flag list:
python3 perf-report.py --help (this wrapper's own -h stops short of it).

  perf-report.sh --compare --out before-vs-after-<ts> \
    --before-har-analytics before-<ts>/weld-sessions.har --after-har-analytics after-<ts>/weld-sessions.har \
    --before-capture-analytics capture-<ts>/analytics-metrics.json --after-capture-analytics after-<ts>/analytics-1/analytics-metrics.json
USAGE
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

VENV_DIR="$NOVHUB_ROOT/.venv"
if [ -d "$VENV_DIR" ]; then
  log "already exists: $VENV_DIR"
else
  python3 -m venv "$VENV_DIR"
  log "created: $VENV_DIR"
fi

exec "$VENV_DIR/bin/python" "$NOVHUB_ROOT/perf-report.py" "$@"
