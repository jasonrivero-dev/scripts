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
            cur.execute("DELETE FROM weld_presets_associations WHERE robot_id IN %s", (ids,))
            assoc = cur.rowcount
            cur.execute("DELETE FROM weld_monitoring_presets WHERE robot_id IN %s", (ids,))
            cur.execute("DELETE FROM robot WHERE id IN %s", (ids,))
            robots = cur.rowcount
        conn.commit()
        if robots == 0:
            print("already removed: nothing found")
        else:
            print(f"removed: {robots} robots, {assoc} weld_presets_associations rows")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["seed", "remove"])
    args = parser.parse_args()
    seed() if args.action == "seed" else remove()
