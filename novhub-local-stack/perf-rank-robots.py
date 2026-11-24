#!/usr/bin/env python3
"""HUB-106: read-only ranking of a target's robots by weld_run total, over a wide fixed date
range, to pick a BEFORE/AFTER robot on a target whose data we don't control. Never writes.
"""
import argparse
import os
import sys
import time

import requests

NOVAPI_URL = os.environ.get("NOVAPI_URL")
SECRET_FILE = os.environ.get("PERF_SECRET_FILE")
START_DATE = os.environ.get("PERF_RANK_START", "2015-01-01")
END_DATE = os.environ.get("PERF_RANK_END", "2030-12-31")
PAUSE_S = float(os.environ.get("PERF_RANK_PAUSE_MS", "200")) / 1000.0
TOTAL_CAP = 10000

if not NOVAPI_URL:
    sys.exit("NOVAPI_URL is not set - run this via perf-rank-robots.sh, not directly")
if not SECRET_FILE:
    sys.exit("PERF_SECRET_FILE is not set - run this via perf-rank-robots.sh, not directly")


def login():
    email, password = open(SECRET_FILE).read().strip().split(":", 1)
    resp = requests.post(f"{NOVAPI_URL}/api/v1/auth/signin", json={"email": email, "password": password}, timeout=10)
    if not resp.ok:
        # NovApi's signin body is a generic {error, message} - never echoes back the
        # credentials - so it's safe to show and tells us more than a bare status code.
        sys.exit(f"signin failed: {resp.status_code} {resp.text.strip()}")
    return resp.json()["token"]


def list_robots(headers):
    resp = requests.get(f"{NOVAPI_URL}/api/v2/users/robots", headers=headers,
                         params={"per_page": 10000}, timeout=30)
    resp.raise_for_status()
    return resp.json()["data"]


def weld_run_total(headers, robot_id):
    url = f"{NOVAPI_URL}/api/v2/users/robots/{robot_id}/weld_run"
    resp = requests.get(url, headers=headers,
                         params={"start": START_DATE, "end": END_DATE, "page": 1, "per_page": 1}, timeout=30)
    resp.raise_for_status()
    return resp.json().get("total", 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--robot-id", type=int, help="look up just this one robot's total "
                     "(machine-readable: prints a bare integer, or 10000+, to stdout - "
                     "nothing else) instead of ranking every robot")
    ap.add_argument("--robot-exists", type=int, help="print yes/no for whether this robot id "
                     "is in NovApi's robot list, instead of ranking or totaling")
    args = ap.parse_args()

    print(f"[INFO] date range: {START_DATE} to {END_DATE} (fixed, printed - same every run)", file=sys.stderr)
    token = login()
    headers = {"Authorization": f"bearer {token}"}

    if args.robot_exists is not None:
        robots = list_robots(headers)
        print("yes" if any(r.get("id") == args.robot_exists for r in robots) else "no")
        return

    if args.robot_id is not None:
        total = weld_run_total(headers, args.robot_id)
        print("10000+" if total == TOTAL_CAP else total)
        return

    robots = list_robots(headers)
    print(f"[INFO] {len(robots)} robots found - asking weld_run for each, one at a time, "
          f"{int(PAUSE_S * 1000)}ms apart, no retries", file=sys.stderr)

    ranked = []
    for i, robot in enumerate(robots):
        robot_id = robot.get("id")
        name = robot.get("name", "")
        try:
            total = weld_run_total(headers, robot_id)
        except requests.RequestException as e:
            ranked.append({"id": robot_id, "name": name, "total": None, "error": str(e)})
        else:
            ranked.append({"id": robot_id, "name": name, "total": total})
        if i < len(robots) - 1:
            time.sleep(PAUSE_S)

    ranked.sort(key=lambda r: (r["total"] is None, -(r["total"] or 0)))

    print(f"\n{'robot name':<30} {'id':>8}  weld_run total ({START_DATE} to {END_DATE})")
    print("-" * 80)
    for r in ranked:
        if r["total"] is None:
            print(f"{r['name']:<30} {r['id']!s:>8}  ERROR: {r['error']}")
        else:
            display = "10000+" if r["total"] == TOTAL_CAP else str(r["total"])
            print(f"{r['name']:<30} {r['id']!s:>8}  {display}")


if __name__ == "__main__":
    main()
