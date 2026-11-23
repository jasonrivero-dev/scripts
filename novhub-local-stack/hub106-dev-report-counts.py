#!/usr/bin/env python3
"""HUB-106: read-only. Counts QC reports (weld_test_reports) per robot on dev, through the open dev DB tunnel
(./cloud-tunnel.sh open --env dev). Usage: python3 -I hub106-dev-report-counts.py
Prints robot_id and counts only. Never prints a secret."""
import os
import sys

STACK_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, STACK_DIR)

import psycopg2  # noqa: E402
from cloud_common import read_kv, require  # noqa: E402

SECRETS_FILE = os.path.join(STACK_DIR, ".state/secrets/novai-dev/DB.secrets")
PORTS_FILE = os.path.join(STACK_DIR, "cloud-tunnel-ports.env")
PORT_KEY = "DEV_DB_LOCAL_PORT"
CONNECT_TIMEOUT_SECONDS = 10

QUERY = """
SELECT robot_id,
       count(*) AS reports_total,
       count(*) FILTER (WHERE deleted_at IS NULL) AS reports_active,
       count(DISTINCT run_number) FILTER (WHERE deleted_at IS NULL) AS runs_with_reports
FROM weld_test_reports
GROUP BY robot_id
ORDER BY reports_active DESC
"""


def main():
    kv = read_kv(SECRETS_FILE)
    require(kv, ["name", "username", "password"], SECRETS_FILE)
    port = read_kv(PORTS_FILE).get(PORT_KEY)
    if not port:
        sys.exit(f"missing {PORT_KEY} in {PORTS_FILE}")
    conn = psycopg2.connect(
        host="127.0.0.1", port=port, dbname=kv["name"], user=kv["username"],
        password=kv["password"], connect_timeout=CONNECT_TIMEOUT_SECONDS, sslmode="require",
    )
    conn.set_session(readonly=True, autocommit=True)
    try:
        with conn.cursor() as cur:
            cur.execute(QUERY)
            rows = cur.fetchall()
    finally:
        conn.close()
    print("robot_id  reports_total  reports_active  runs_with_reports")
    for robot_id, total, active, runs in rows:
        print(f"{robot_id:<9} {total:<14} {active:<15} {runs}")
    print(f"robots with reports: {len(rows)}")


if __name__ == "__main__":
    main()
