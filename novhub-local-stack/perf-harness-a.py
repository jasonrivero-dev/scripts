#!/usr/bin/env python3
"""HUB-106 variant A baseline: today's per-run call pattern, timed against the seeded data.

Read-only against NovApi - no code changes, no writes. Logs in as the seeded synthetic test
user, calls the weld_run list endpoint once, then calls weld_test_reports once per returned
row. Today's actual code (WeldSessions.tsx/WeldInformation.tsx) fires all of those per-run
calls at once via Promise.all, capped only by the browser's per-host connection limit - 6 for
HTTP/1.1, which is what this local NovApi answers with (confirmed: no HTTP/2). So "parallel_6"
below is variant A; "sequential" is shown only for context, it is not today's real code path.
"""
import json
import os
import statistics
import time
from concurrent.futures import ThreadPoolExecutor

import requests

NOVAPI_URL = os.environ.get("NOVAPI_URL", "http://127.0.0.1:3000")
ROBOT_ID = int(os.environ.get("PERF_ROBOT_ID", "900001"))
PER_PAGE = int(os.environ.get("PERF_PER_PAGE", "2000"))  # confirmed by NOVAPP: WeldSessions.tsx/WeldInformation.tsx default
TRIALS = int(os.environ.get("PERF_TRIALS", "3"))
PARALLEL_CONCURRENCY = int(os.environ.get("PERF_PARALLEL_CONCURRENCY", "6"))  # a browser's typical per-origin limit
SECRET_FILE = os.environ.get(
    "PERF_SECRET_FILE",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), ".state", "secrets", "perf-test-user.secret"),
)


def login():
    with open(SECRET_FILE) as f:
        email, password = f.read().strip().split(":", 1)
    resp = requests.post(
        f"{NOVAPI_URL}/api/v1/auth/signin",
        json={"email": email, "password": password}, timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["token"]


def timed_get(url, headers, params=None):
    start = time.perf_counter()
    resp = requests.get(url, headers=headers, params=params, timeout=30)
    elapsed = time.perf_counter() - start
    resp.raise_for_status()
    return elapsed, len(resp.content), resp.json()


def fetch_list(headers):
    list_url = f"{NOVAPI_URL}/api/v2/users/robots/{ROBOT_ID}/weld_run"
    list_time, list_bytes, list_body = timed_get(list_url, headers, {"page": 1, "per_page": PER_PAGE})
    return list_time, list_bytes, list_body.get("data", [])


def report_params(row):
    return {
        "job_id": row.get("job_id", ""), "part_id": row.get("part_id", ""),
        "serial_id": row.get("serial_id", ""), "weld_id": row.get("weld_id", ""),
        "run_id": row.get("run_id", ""),
    }


def summarize_run(list_time, list_bytes, row_count, per_run_times, per_run_bytes, wall_clock_s):
    return {
        "list_time_s": list_time, "list_bytes": list_bytes, "row_count": row_count,
        "per_run_request_count": len(per_run_times),
        "per_run_total_time_s": sum(per_run_times),
        "per_run_wall_clock_s": wall_clock_s,
        "per_run_total_bytes": sum(per_run_bytes),
        "per_run_median_s": statistics.median(per_run_times) if per_run_times else 0,
        "per_run_slowest_s": max(per_run_times) if per_run_times else 0,
        "total_elapsed_s": list_time + wall_clock_s,
        "total_request_count": 1 + len(per_run_times),
        "total_bytes": list_bytes + sum(per_run_bytes),
    }


def run_trial_sequential(token):
    """Calls weld_test_reports one after another - NOT today's actual code path
    (that's parallel_6 below); shown only for context."""
    headers = {"Authorization": f"bearer {token}"}
    list_time, list_bytes, rows = fetch_list(headers)
    report_url = f"{NOVAPI_URL}/api/v2/users/robots/{ROBOT_ID}/weld_test_reports"

    per_run_times = []
    per_run_bytes = []
    wall_start = time.perf_counter()
    for row in rows:
        t, b, _ = timed_get(report_url, headers, report_params(row))
        per_run_times.append(t)
        per_run_bytes.append(b)
    wall_clock_s = time.perf_counter() - wall_start

    return summarize_run(list_time, list_bytes, len(rows), per_run_times, per_run_bytes, wall_clock_s)


def run_trial_parallel(token, concurrency):
    """Fires weld_test_reports calls N at a time - this IS today's actual code path:
    WeldSessions.tsx/WeldInformation.tsx fire all calls via Promise.all, capped at 6 by the
    browser's per-host HTTP/1.1 connection limit (confirmed: this NovApi answers HTTP/1.1)."""
    headers = {"Authorization": f"bearer {token}"}
    list_time, list_bytes, rows = fetch_list(headers)
    report_url = f"{NOVAPI_URL}/api/v2/users/robots/{ROBOT_ID}/weld_test_reports"

    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        results = list(pool.map(lambda row: timed_get(report_url, headers, report_params(row)), rows))
    wall_clock_s = time.perf_counter() - wall_start

    per_run_times = [r[0] for r in results]
    per_run_bytes = [r[1] for r in results]
    return summarize_run(list_time, list_bytes, len(rows), per_run_times, per_run_bytes, wall_clock_s)


def summarize(trials):
    def col(key):
        return [t[key] for t in trials]

    def stat(key):
        values = col(key)
        return {"median": statistics.median(values), "slowest": max(values)}

    return {
        "trials": len(trials),
        "row_count": trials[0]["row_count"] if trials else 0,
        "total_elapsed_s": stat("total_elapsed_s"),
        "list_time_s": stat("list_time_s"),
        "per_run_total_time_s": stat("per_run_total_time_s"),
        "per_run_wall_clock_s": stat("per_run_wall_clock_s"),
        "per_run_median_s": stat("per_run_median_s"),
        "per_run_slowest_s": stat("per_run_slowest_s"),
        "total_bytes": stat("total_bytes"),
        "total_request_count": stat("total_request_count"),
    }


def variant_block(trial_fn):
    trials = [trial_fn() for _ in range(TRIALS)]
    return {
        "cold": trials[0],
        "warm": summarize(trials[1:]) if len(trials) > 1 else None,
        "all_trials": summarize(trials),
    }


def main():
    token = login()
    summary = {
        "variant": "A (current per-run calls)",
        "robot_id": ROBOT_ID, "per_page": PER_PAGE,
        "note": "All calls are to 127.0.0.1 - no real network latency is included in these numbers. "
                "This NovApi answers HTTP/1.1 (confirmed), so the browser's 6-connection-per-host cap applies.",
        "sequential": {
            "description": "one weld_test_reports call after another - NOT today's actual code path, "
                            "shown only for context",
            **variant_block(lambda: run_trial_sequential(token)),
        },
        "parallel_6": {
            "description": f"weld_test_reports calls {PARALLEL_CONCURRENCY} at a time via a thread pool - "
                            "THIS IS variant A, today's actual code path (Promise.all capped by the "
                            "browser's HTTP/1.1 per-host connection limit)",
            **variant_block(lambda: run_trial_parallel(token, PARALLEL_CONCURRENCY)),
        },
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
