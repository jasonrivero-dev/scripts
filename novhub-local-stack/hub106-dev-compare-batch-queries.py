#!/usr/bin/env python3
"""HUB-106: read-only. Needs the dev tunnel open (./cloud-tunnel.sh open --env dev).
Usage: python3 -I hub106-dev-compare-batch-queries.py
Compares the old (four-column) and the simplified getByRobotIdAndTuples SQL on the
real report tuples of each robot that has QC reports on dev, through the open dev DB tunnel.
Also counts runs whose reports carry more than one tuple (how rare that case is).
Prints robot ids, counts and run numbers only. Never prints a secret."""
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
MAX_RUNS_SHOWN = 20

# Every tuple on the robot, deleted or not, sent twice to also exercise the dedupe step.
INPUT_CTE = """
input AS (
  SELECT DISTINCT run_number, work_order_ref, spool_ref, welder_id_ref
  FROM weld_test_reports WHERE robot_id = %(robot_id)s AND run_number IS NOT NULL
),
input_doubled AS (SELECT * FROM input UNION ALL SELECT * FROM input),
requested_runs AS (
  SELECT DISTINCT run_number, work_order_ref, spool_ref, welder_id_ref FROM input_doubled
)
"""

JOIN = """
FROM requested_runs AS t
JOIN weld_test_reports
  ON weld_test_reports.robot_id = %(robot_id)s
  AND weld_test_reports.work_order_ref = t.work_order_ref
  AND weld_test_reports.spool_ref = t.spool_ref
  AND weld_test_reports.welder_id_ref = t.welder_id_ref
  AND weld_test_reports.run_number = t.run_number
  AND weld_test_reports.deleted_at IS NULL
"""

OLD_SQL = f"""
WITH {INPUT_CTE}
SELECT DISTINCT ON (t.run_number, t.work_order_ref, t.spool_ref, t.welder_id_ref)
  t.run_number AS run_number, weld_test_reports.test_status AS test_status,
  (count(*) OVER (PARTITION BY t.run_number, t.work_order_ref, t.spool_ref, t.welder_id_ref))::int AS report_count
{JOIN}
ORDER BY t.run_number, t.work_order_ref, t.spool_ref, t.welder_id_ref, weld_test_reports.id DESC
"""

NEW_SQL = f"""
WITH {INPUT_CTE}
SELECT DISTINCT ON (t.run_number) t.run_number AS run_number, weld_test_reports.test_status AS test_status,
  (count(*) OVER (PARTITION BY t.run_number))::int AS report_count
{JOIN}
ORDER BY t.run_number, weld_test_reports.id DESC
"""

ROBOTS_SQL = "SELECT DISTINCT robot_id FROM weld_test_reports ORDER BY robot_id"

MULTI_TUPLE_SQL = """
SELECT run_number FROM (
  SELECT DISTINCT run_number, work_order_ref, spool_ref, welder_id_ref
  FROM weld_test_reports WHERE robot_id = %(robot_id)s AND deleted_at IS NULL AND run_number IS NOT NULL
) d GROUP BY run_number HAVING count(*) > 1 ORDER BY run_number
"""


def as_map(rows, keep_tuple_rows):
    # old query: one row per tuple; keyed by run_number the last row wins, like the route does.
    out = {}
    for run_number, status, count in rows:
        out[run_number] = (status, count)
    return out, len(rows)


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
    failed = False
    try:
        with conn.cursor() as cur:
            cur.execute(ROBOTS_SQL)
            robots = [r[0] for r in cur.fetchall()]
            print("robot_id  runs_old  runs_new  differing_runs  runs_with_multiple_tuples")
            for robot_id in robots:
                params = {"robot_id": robot_id}
                cur.execute(OLD_SQL, params)
                old_rows = cur.fetchall()
                cur.execute(NEW_SQL, params)
                new_rows = cur.fetchall()
                cur.execute(MULTI_TUPLE_SQL, params)
                multi = [r[0] for r in cur.fetchall()]
                old_map, _ = as_map(old_rows, True)
                new_map, _ = as_map(new_rows, False)
                differing = sorted(
                    r for r in set(old_map) | set(new_map) if old_map.get(r) != new_map.get(r)
                )
                if differing:
                    failed = True
                print(f"{robot_id:<9} {len(old_map):<9} {len(new_map):<9} {len(differing):<15} {len(multi)}")
                if differing:
                    print(f"  differing run_numbers (first {MAX_RUNS_SHOWN}): {differing[:MAX_RUNS_SHOWN]}")
                if multi:
                    print(f"  runs with more than one tuple (first {MAX_RUNS_SHOWN}): {multi[:MAX_RUNS_SHOWN]}")
    finally:
        conn.close()
    print("RESULT:", "DIFFERENCES FOUND" if failed else "old and simplified queries return identical results")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
