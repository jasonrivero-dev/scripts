#!/usr/bin/env python3
"""HUB-106: sweeps page/batch size on the SAME frozen dataset (no re-ingest) to show how
response time grows with size - a stand-in for "more data" when the real dataset can't grow
to production scale locally. Read-only against NovApi.
"""
import json
import os
import statistics
import sys
import time

import requests

NOVAPI_URL = os.environ.get("NOVAPI_URL", "http://127.0.0.1:3000")
ROBOT_ID = int(os.environ.get("PERF_ROBOT_ID", "910001"))
PAGE_SIZES = [int(x) for x in os.environ.get("PERF_SWEEP_PAGE_SIZES", "100,500,1000,2000").split(",")]
BATCH_SIZES = [int(x) for x in os.environ.get("PERF_SWEEP_BATCH_SIZES", "100,250,500").split(",")]
TRIALS = int(os.environ.get("PERF_SWEEP_TRIALS", "3"))
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SECRET_FILE = os.environ.get(
    "PERF_SECRET_FILE", os.path.join(SCRIPT_DIR, ".state", "secrets", "perf-test-user.secret"))
NOVAPI_LOG_FILE = os.environ.get("NOVAPI_LOG_FILE", os.path.join(SCRIPT_DIR, ".state", "novapi.log"))


def detect_brand():
    """Ground truth: NovApi's own startup log line + NovApp's .env - never an ambient env var."""
    novapi_brand = "unknown"
    if os.path.exists(NOVAPI_LOG_FILE):
        with open(NOVAPI_LOG_FILE) as f:
            lines = [l for l in f if "IS_NOVAI" in l]
        if lines:
            novapi_brand = "NovAI" if "true" in lines[-1] else ("SWR" if "false" in lines[-1] else "unknown")
    novapp_brand = "unknown"
    novapp_env = os.path.expanduser(os.environ.get("NOVAPP_REPO", "~/dev/novhub") + "/.env")
    if os.path.exists(novapp_env):
        with open(novapp_env) as f:
            for line in f:
                if line.startswith("VITE_IS_NOVAI="):
                    novapp_brand = "NovAI" if line.strip().endswith("true") else "SWR"
    return {"novapi": novapi_brand, "novapp": novapp_brand}


def login():
    email, password = open(SECRET_FILE).read().strip().split(":", 1)
    resp = requests.post(f"{NOVAPI_URL}/api/v1/auth/signin", json={"email": email, "password": password}, timeout=10)
    resp.raise_for_status()
    return resp.json()["token"]


def timed(method, url, headers, **kwargs):
    start = time.perf_counter()
    resp = requests.request(method, url, headers=headers, timeout=60, **kwargs)
    elapsed = time.perf_counter() - start
    resp.raise_for_status()
    return elapsed, resp.json()


def sweep_weld_run(headers):
    url = f"{NOVAPI_URL}/api/v2/users/robots/{ROBOT_ID}/weld_run"
    results = {}
    for size in PAGE_SIZES:
        times = [timed("GET", url, headers, params={"page": 1, "per_page": size})[0] for _ in range(TRIALS)]
        results[size] = {"median_s": statistics.median(times), "slowest_s": max(times), "trials": TRIALS}
    return results


def sweep_batch(headers, label, path, body_key, rows):
    url = f"{NOVAPI_URL}/api/v2/users/robots/{ROBOT_ID}/{path}"
    results = {}
    for size in BATCH_SIZES:
        batch = rows[:size]
        if body_key == "runs":
            body = {"runs": [{"run_id": int(r["run_id"]), "part_id": r["part_id"],
                               "serial_id": r["serial_id"], "weld_id": str(r["weld_id"])} for r in batch]}
        else:
            body = {"run_ids": [int(r["run_id"]) for r in batch]}
        times = [timed("POST", url, headers, json=body)[0] for _ in range(TRIALS)]
        results[size] = {"median_s": statistics.median(times), "slowest_s": max(times), "trials": TRIALS,
                          "rows_sent": len(batch)}
    return results


def main():
    brand = detect_brand()
    if brand["novapi"] != "NovAI" or brand["novapp"] != "NovAI":
        sys.exit(f"FAILED: not running as NovAI on both sides ({brand}) - "
                  f"TAS (the customer this measures) runs NovAI robots only")

    token = login()
    headers = {"Authorization": f"bearer {token}"}
    list_url = f"{NOVAPI_URL}/api/v2/users/robots/{ROBOT_ID}/weld_run"
    _, body = timed("GET", list_url, headers, params={"page": 1, "per_page": 2000})
    rows = body.get("data", [])

    summary = {
        "robot_id": ROBOT_ID, "available_rows": len(rows), "brand": brand,
        "note": "Same frozen dataset for every size - this sweep shows how time grows with "
                "request size, not with dataset size.",
        "weld_run_list_by_per_page": sweep_weld_run(headers),
        "weld_test_reports_batch_by_size": sweep_batch(headers, "batch reports", "weld_test_reports/batch", "runs", rows),
        "weld_stats_batch_by_size": sweep_batch(headers, "batch stats", "weld_stats/batch", "run_ids", rows),
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
