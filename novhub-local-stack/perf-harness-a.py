#!/usr/bin/env python3
"""HUB-106 endpoint baseline: times the five endpoints NOVAPI identified as relevant to the
Analytics page, against the real ingested robots (perf-ingester-load.sh's output). Read-only
against NovApi - no NovApi/NovApp code changes. Logs in as the seeded synthetic test user.
Saves every trial's full result plus the slice of NovApi's own per-request log covering that
run, under a dated folder, so results can be kept and compared before/after.

Endpoints timed, per robot, per trial:
  a) GET  weld_run                - the page's run list
  b) GET  weld_test_reports x N   - one per run, fired PERF_PARALLEL_CONCURRENCY at a time
                                     (today's real per-run call pattern)
  c) POST weld_test_reports/batch - PERF_BATCH_SIZE runs per call
  d) POST weld_stats/batch        - PERF_BATCH_SIZE run_ids per call
  e) GET  weld_stats               - one page-wide call

(b) and (c) currently 500 here - NovApi's weld_test_reports route depends on S3 attachment
listing, and local AWS creds/bucket aren't real (flagged separately, not fixed by this script).
A block where every call failed is marked "baseline": "unavailable (all calls failed)" instead
of reporting a failed call's time as if it were a real number.
"""
import json
import os
import statistics
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import requests

NOVAPI_URL = os.environ.get("NOVAPI_URL", "http://127.0.0.1:3000")
ROBOT_IDS = [int(x) for x in os.environ.get("PERF_ROBOT_IDS", "910001,910002").split(",")]
PER_PAGE = int(os.environ.get("PERF_PER_PAGE", "2000"))
TRIALS = int(os.environ.get("PERF_TRIALS", "3"))
PARALLEL_CONCURRENCY = int(os.environ.get("PERF_PARALLEL_CONCURRENCY", "6"))
BATCH_SIZE = int(os.environ.get("PERF_BATCH_SIZE", "500"))
STATS_RANGE_DAYS = int(os.environ.get("PERF_STATS_RANGE_DAYS", "60"))

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SECRET_FILE = os.environ.get(
    "PERF_SECRET_FILE", os.path.join(SCRIPT_DIR, ".state", "secrets", "perf-test-user.secret"))
NOVAPI_LOG_FILE = os.environ.get("NOVAPI_LOG_FILE", os.path.join(SCRIPT_DIR, ".state", "novapi.log"))
RESULTS_ROOT = os.environ.get("PERF_RESULTS_DIR", os.path.join(SCRIPT_DIR, ".state", "perf-results"))


def login():
    with open(SECRET_FILE) as f:
        email, password = f.read().strip().split(":", 1)
    resp = requests.post(
        f"{NOVAPI_URL}/api/v1/auth/signin", json={"email": email, "password": password}, timeout=10)
    resp.raise_for_status()
    return resp.json()["token"]


def timed_call(method, url, headers, **kwargs):
    """Never raises on a bad status - a 500 is itself a measurement, not a reason to abort the
    whole baseline. Returns (elapsed_s, byte_count, status_code, parsed_body_or_None)."""
    start = time.perf_counter()
    resp = requests.request(method, url, headers=headers, timeout=30, **kwargs)
    elapsed = time.perf_counter() - start
    body = None
    if resp.status_code < 400:
        try:
            body = resp.json()
        except ValueError:
            body = None
    return elapsed, len(resp.content), resp.status_code, body


def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i:i + size]


def rate_stats(results, extra=None):
    """results: list of (elapsed_s, byte_count, status_code, body) tuples. Stats are computed
    only over the successful calls - a failed call's time is not a real measurement."""
    ok = [r for r in results if r[2] < 400]
    statuses = sorted({r[2] for r in results})
    out = {
        "call_count": len(results),
        "error_count": len(results) - len(ok),
        "statuses": statuses,
    }
    if ok:
        times = [r[0] for r in ok]
        out.update({
            "baseline": "ok",
            "total_time_s": sum(times),
            "median_s": statistics.median(times),
            "slowest_s": max(times),
            "total_bytes": sum(r[1] for r in ok),
        })
    else:
        out["baseline"] = "unavailable (all calls failed)"
    if extra:
        out.update(extra)
    return out


def fetch_list(headers, robot_id):
    url = f"{NOVAPI_URL}/api/v2/users/robots/{robot_id}/weld_run"
    t, b, status, body = timed_call("GET", url, headers, params={"page": 1, "per_page": PER_PAGE})
    rows = (body or {}).get("data", [])
    result = {"call_count": 1, "statuses": [status]}
    if status < 400:
        result.update({"baseline": "ok", "time_s": t, "bytes": b, "row_count": len(rows)})
    else:
        result["baseline"] = "unavailable (call failed)"
    return result, rows


def report_params(row):
    return {"job_id": row.get("job_id", ""), "part_id": row.get("part_id", ""),
            "serial_id": row.get("serial_id", ""), "weld_id": row.get("weld_id", ""),
            "run_id": row.get("run_id", "")}


def per_run_calls(headers, robot_id, rows):
    """(b) variant A: weld_test_reports fired PARALLEL_CONCURRENCY at a time - today's real
    per-run call pattern (Promise.all capped by the browser's HTTP/1.1 per-host limit)."""
    url = f"{NOVAPI_URL}/api/v2/users/robots/{robot_id}/weld_test_reports"
    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=PARALLEL_CONCURRENCY) as pool:
        results = list(pool.map(lambda row: timed_call("GET", url, headers, params=report_params(row)), rows))
    wall_clock_s = time.perf_counter() - wall_start
    return rate_stats(results, {"wall_clock_s": wall_clock_s, "concurrency": PARALLEL_CONCURRENCY})


def batch_report_calls(headers, robot_id, rows):
    """(c) POST weld_test_reports/batch, BATCH_SIZE runs per call."""
    url = f"{NOVAPI_URL}/api/v2/users/robots/{robot_id}/weld_test_reports/batch"
    batches = list(chunked(rows, BATCH_SIZE))
    results = []
    for batch in batches:
        body = {"runs": [{"run_id": int(r["run_id"]), "part_id": r["part_id"],
                           "serial_id": r["serial_id"], "weld_id": str(r["weld_id"])} for r in batch]}
        results.append(timed_call("POST", url, headers, json=body))
    return rate_stats(results, {"batch_size": BATCH_SIZE})


def batch_stats_calls(headers, robot_id, rows):
    """(d) POST weld_stats/batch, BATCH_SIZE run_ids per call."""
    url = f"{NOVAPI_URL}/api/v2/users/robots/{robot_id}/weld_stats/batch"
    run_ids = [int(r["run_id"]) for r in rows]
    results = [timed_call("POST", url, headers, json={"run_ids": batch})
               for batch in chunked(run_ids, BATCH_SIZE)]
    return rate_stats(results, {"batch_size": BATCH_SIZE})


def page_wide_stats_call(headers, robot_id):
    """(e) GET weld_stats, one page-wide call over a date range wide enough to cover all
    currently-seeded data."""
    url = f"{NOVAPI_URL}/api/v2/users/robots/{robot_id}/weld_stats"
    end = datetime.now(timezone.utc).date() + timedelta(days=1)
    start = end - timedelta(days=STATS_RANGE_DAYS)
    t, b, status, body = timed_call("GET", url, headers, params={
        "start": start.isoformat(), "end": end.isoformat(), "page": 1, "per_page": 10000})
    if status < 400:
        return {"baseline": "ok", "time_s": t, "bytes": b, "statuses": [status],
                "weld_done": (body or {}).get("weld_done")}
    return {"baseline": "unavailable (call failed)", "statuses": [status]}


ENDPOINT_KEYS = ["a_weld_run_list", "b_per_run_weld_test_reports", "c_batch_weld_test_reports",
                 "d_batch_weld_stats", "e_page_wide_weld_stats"]


def _endpoint_total(entry):
    """The real end-to-end time for this endpoint's trial - wall_clock_s for (b) (N calls
    via the concurrency pool, not any single call's latency), time_s for a single-call
    endpoint (a/e), total_time_s (sum of its 1-2 sequential batches) for (c)/(d)."""
    if entry.get("baseline") != "ok":
        return None
    if "wall_clock_s" in entry:
        return entry["wall_clock_s"]
    if "time_s" in entry:
        return entry["time_s"]
    return entry.get("total_time_s")


def summarize_results(trials, robot_ids):
    """Trial 0 is cold; trials 1+ are warm - median/slowest of each warm trial's own
    end-to-end total, so a flaky single warm trial doesn't skew the headline number."""
    summary = {}
    for rid in robot_ids:
        summary[rid] = {}
        for key in ENDPOINT_KEYS:
            entries = [t[rid][key] for t in trials]
            cold, warm = entries[0], entries[1:]
            warm_totals = [t for t in (_endpoint_total(e) for e in warm) if t is not None]
            summary[rid][key] = {
                "cold_s": _endpoint_total(cold),
                "cold_ok": cold.get("baseline") == "ok",
                "warm_median_s": statistics.median(warm_totals) if warm_totals else None,
                "warm_slowest_s": max(warm_totals) if warm_totals else None,
                "trials_ok": sum(1 for e in entries if e.get("baseline") == "ok"),
                "trials_total": len(entries),
            }
    return summary


def measure_robot(headers, robot_id):
    list_result, rows = fetch_list(headers, robot_id)
    return {
        "robot_id": robot_id,
        "a_weld_run_list": list_result,
        "b_per_run_weld_test_reports": per_run_calls(headers, robot_id, rows),
        "c_batch_weld_test_reports": batch_report_calls(headers, robot_id, rows),
        "d_batch_weld_stats": batch_stats_calls(headers, robot_id, rows),
        "e_page_wide_weld_stats": page_wide_stats_call(headers, robot_id),
    }


def save_results(summary):
    os.makedirs(RESULTS_ROOT, exist_ok=True)
    run_dir = os.path.join(RESULTS_ROOT, datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    os.makedirs(run_dir)
    with open(os.path.join(run_dir, "results.json"), "w") as f:
        json.dump(summary, f, indent=2)
    return run_dir


def log_line_count():
    if not os.path.exists(NOVAPI_LOG_FILE):
        return 0
    with open(NOVAPI_LOG_FILE) as f:
        return sum(1 for _ in f)


def log_tail(start_line):
    if not os.path.exists(NOVAPI_LOG_FILE):
        return []
    with open(NOVAPI_LOG_FILE) as f:
        return f.readlines()[start_line:]


def main():
    token = login()
    headers = {"Authorization": f"bearer {token}"}

    log_start_line = log_line_count()
    trials = [{rid: measure_robot(headers, rid) for rid in ROBOT_IDS} for _ in range(TRIALS)]

    summary = {
        "note": "All calls are to 127.0.0.1 - no real network latency included. NovApi answers "
                "HTTP/1.1, so (b)'s concurrency matches the browser's real per-host cap. A "
                "\"baseline\": \"unavailable\" block means every call in it failed (see "
                "statuses/error_count) - that is not a timing result, not a zero. Trial 0 is "
                "cold; trials 1+ are warm.",
        "robot_ids": ROBOT_IDS, "per_page": PER_PAGE, "batch_size": BATCH_SIZE,
        "parallel_concurrency": PARALLEL_CONCURRENCY,
        "summary": summarize_results(trials, ROBOT_IDS),
        "trials": trials,
    }

    run_dir = save_results(summary)
    with open(os.path.join(run_dir, "novapi.log.slice"), "w") as f:
        f.writelines(log_tail(log_start_line))

    print(json.dumps(summary, indent=2))
    print(f"\nsaved to: {run_dir}")


if __name__ == "__main__":
    main()
