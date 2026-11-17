#!/usr/bin/env python3
"""HUB-106: seed/remove the minimal NovApi Postgres rows opensearch-ingester's own
preset-matching logic needs (robot + weld_monitoring_presets with real matching criteria).
Does NOT write OpenSearch docs or weld_presets_associations - perfload does that itself,
exercising the ingester's real preset-matching code instead of a hand-written association row.
"""
import argparse
import json
import os
import sys

import psycopg2

ROBOT_ID_START = int(os.environ.get("PERF_ING_ROBOT_ID_START", "910001"))
ROBOT_COUNT = int(os.environ.get("PERF_ING_ROBOT_COUNT", "2"))

NOVAPI_HOST = os.environ.get("NOVAPI_DB_HOST", "127.0.0.1")
NOVAPI_PORT = os.environ.get("NOVAPI_DB_PORT", "5433")
NOVAPI_DB = os.environ.get("NOVAPI_DB_NAME", "swrdb_aggr")
NOVAPI_USER = os.environ.get("NOVAPI_DB_USER", "postgres")
NOVAPI_PASSWORD = os.environ.get("NOVAPI_DB_PASSWORD")
PERF_SECRET_FILE = os.environ.get(
    "PERF_SECRET_FILE",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), ".state", "secrets", "perf-test-user.secret"),
)

# Must equal cmd/perfload's matchCriteria exactly, or FindBestPreset scores 0 and no
# weld_presets_associations row gets written.
MATCH_CRITERIA = {
    "gas_type": 1, "material_type": 1, "joint_type": 8,
    "weld_position": 1, "material_thickness": 1, "wire_type": 1, "wire_size": 1,
}


def robot_ids():
    return list(range(ROBOT_ID_START, ROBOT_ID_START + ROBOT_COUNT))


def connect():
    if not NOVAPI_PASSWORD:
        sys.exit("NOVAPI_DB_PASSWORD is not set")
    return psycopg2.connect(host=NOVAPI_HOST, port=NOVAPI_PORT, dbname=NOVAPI_DB,
                             user=NOVAPI_USER, password=NOVAPI_PASSWORD)


def seed():
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM robot WHERE id = %s", (ROBOT_ID_START,))
            if cur.fetchone() is not None:
                print(f"already seeded: robot {ROBOT_ID_START} exists - run `remove` first to reseed")
                return
            for robot_id in robot_ids():
                cur.execute(
                    "INSERT INTO robot (id, name, customer, location, updated_at) "
                    "VALUES (%s, %s, %s, %s, now())",
                    (robot_id, f"PERF-ING-{robot_id}", "HUB-106 Ingester Test", "synthetic"),
                )
                cur.execute(
                    "INSERT INTO weld_monitoring_presets (robot_id, procedure, settings) VALUES (%s, %s, %s)",
                    (robot_id, "HUB-106 ingester-test preset", json.dumps(MATCH_CRITERIA)),
                )
        conn.commit()
        print(f"created: {ROBOT_COUNT} robots ({ROBOT_ID_START}-{ROBOT_ID_START + ROBOT_COUNT - 1}) "
              f"+ 1 matching weld_monitoring_presets row each")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def remove():
    conn = connect()
    try:
        with conn.cursor() as cur:
            ids = tuple(robot_ids())
            cur.execute("DELETE FROM weld_test_reports WHERE robot_id IN %s", (ids,))
            reports = cur.rowcount
            cur.execute("DELETE FROM weld_presets_associations WHERE robot_id IN %s", (ids,))
            assoc = cur.rowcount
            cur.execute("DELETE FROM weld_monitoring_presets WHERE robot_id IN %s", (ids,))
            cur.execute("DELETE FROM robot WHERE id IN %s", (ids,))
            robots = cur.rowcount
        conn.commit()
        if robots == 0:
            print("already removed: nothing found")
        else:
            print(f"removed: {robots} robots, {assoc} weld_presets_associations rows, "
                  f"{reports} weld_test_reports rows")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def perf_test_user_email():
    with open(PERF_SECRET_FILE) as f:
        email, _ = f.read().strip().split(":", 1)
    return email


def seed_reports():
    """Creates weld_test_reports rows for every run already in weld_presets_associations -
    NovApi's weld_test_reports(/batch) endpoints need one per run to return anything.
    part_id/serial_id/weld_id are re-derived with the exact formula cmd/perfload uses, so they
    match what's actually in OpenSearch for these runs."""
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM users WHERE email = %s", (perf_test_user_email(),))
            row = cur.fetchone()
            if row is None:
                sys.exit(f"no user found for {perf_test_user_email()} - run perf-seed.sh seed first")
            user_id = row[0]

            ids = tuple(robot_ids())
            cur.execute(
                "SELECT DISTINCT robot_id, run_id FROM weld_presets_associations WHERE robot_id IN %s",
                (ids,),
            )
            runs = cur.fetchall()
            if not runs:
                print("nothing to seed: no weld_presets_associations rows for these robots yet - "
                      "run perf-ingester-load.sh first")
                return

            created = 0
            for robot_id, run_id in runs:
                cur.execute(
                    "SELECT 1 FROM weld_test_reports WHERE robot_id = %s AND run_number = %s",
                    (robot_id, run_id),
                )
                if cur.fetchone() is not None:
                    continue
                weld_id = str(run_id % 5 + 1)
                cur.execute(
                    "INSERT INTO weld_test_reports "
                    "(user_id, robot_id, work_order_ref, spool_ref, welder_id_ref, run_number, test_status) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                    (user_id, robot_id, f"PERF-ING-PART-{run_id}", f"PERF-ING-SER-{run_id}",
                     weld_id, run_id, "pass"),
                )
                created += 1
        conn.commit()
        if created == 0:
            print("already seeded: weld_test_reports rows exist for every run")
        else:
            print(f"created: {created} weld_test_reports rows")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["seed", "remove", "seed-reports"])
    args = parser.parse_args()
    {"seed": seed, "remove": remove, "seed-reports": seed_reports}[args.action]()
