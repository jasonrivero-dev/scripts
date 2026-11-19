import copy
import importlib.util
import json
import os
import random
import stat
import sys
import tempfile
import unittest
from argparse import Namespace
from datetime import datetime
from pathlib import Path
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
os.environ.update({
    "CLOUD_INGEST_ENV": "dev",
    "CLOUD_INGEST_SECRETS_DIR": "/tmp/cloud-ingest-test-secrets",
    "CLOUD_INGEST_DB_LOCAL_PORT": "25432",
    "CLOUD_INGEST_ES_LOOPBACK": "127.0.0.1",
    "CLOUD_INGEST_AWS_REGION": "us-west-2",
    "CLOUD_INGEST_AWS_PROFILE": "test-profile",
    "CLOUD_INGEST_ROBOT_ID": "1555",
    "CLOUD_INGEST_INGESTER_REPO": "/tmp/cloud-ingest-test-ingester",
    "CLOUD_INGEST_RANK_SCRIPT": "/tmp/cloud-ingest-test-rank",
    "CLOUD_INGEST_LOG_DIR": "/tmp/cloud-ingest-test-logs",
})
sys.path.insert(0, str(SCRIPT_DIR))
spec = importlib.util.spec_from_file_location("cloud_ingest", SCRIPT_DIR / "cloud-ingest.py")
cloud_ingest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud_ingest)


FEEDBACK_TYPES = {
    "autonomy_dist_x_raw": "i16",
    "autonomy_dist_y_raw": "i16",
    "camera_temp": "f32",
    "live_amps": "f32",
    "live_travel_speed": "f32",
    "live_trim": "f32",
    "live_voltage": "f32",
    "live_weave_amplitude": "f32",
    "live_weave_frequency": "f32",
    "live_wfs": "i16",
    "max_gap_measurement": "f32",
    "prescan_gap_measurement": "f32",
}
SCHEMA = {
    "arc_time": "u32",
    "plc_time": "u64",
    "timestamp": "String",
    **FEEDBACK_TYPES,
    "job_id": "String",
}


def make_template():
    rows = []
    for row_index in range(2):
        values = []
        for field, value_type in SCHEMA.items():
            if field == "arc_time":
                value = 97000 + row_index * 10
            elif field == "plc_time":
                value = 21000000 + row_index * 10
            elif field == "timestamp":
                value = f"2026-01-01T12:00:00.{row_index * 10:03d}Z"
            elif field == "job_id":
                value = "NA"
            elif value_type == "i16":
                value = 0
            else:
                value = 0.0
            values.append(value)
        rows.append(values)
    return {
        "version": "2.3",
        "schema": SCHEMA.copy(),
        "values": rows,
        "weld_summary": {"operator_name": "test-operator"},
    }


class CloudIngestTemplateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.range_map = cloud_ingest.load_range_map()

    def test_build_varied_template_uses_ranges_and_preserves_structure(self):
        original = make_template()
        original_copy = copy.deepcopy(original)
        result = cloud_ingest.build_varied_template(
            original, self.range_map, row_count=50, rng=random.Random(7)
        )

        self.assertEqual(original, original_copy)
        self.assertEqual(result["schema"], original["schema"])
        self.assertEqual(result["weld_summary"], original["weld_summary"])
        self.assertEqual(len(result["values"]), 50)

        field_indexes = {field: index for index, field in enumerate(SCHEMA)}
        for field, value_type in FEEDBACK_TYPES.items():
            entry = self.range_map[field]
            low, high = cloud_ingest.numeric_bounds(entry["Probable Range"], field)
            values = [row[field_indexes[field]] for row in result["values"]]
            self.assertGreaterEqual(min(values), low)
            self.assertLessEqual(max(values), high)
            self.assertGreater(len(set(values)), 1)
            if value_type == "i16":
                self.assertTrue(all(type(value) is int for value in values))
            else:
                self.assertTrue(all(type(value) is float for value in values))

        arc_times = [row[field_indexes["arc_time"]] for row in result["values"]]
        plc_times = [row[field_indexes["plc_time"]] for row in result["values"]]
        self.assertEqual(arc_times, [97000 + 10 * index for index in range(50)])
        self.assertEqual(plc_times, [21000000 + 10 * index for index in range(50)])

        timestamps = [
            datetime.fromisoformat(row[field_indexes["timestamp"]].replace("Z", "+00:00"))
            for row in result["values"]
        ]
        self.assertEqual(
            [int((value - timestamps[0]).total_seconds() * 1000) for value in timestamps],
            [10 * index for index in range(50)],
        )
        self.assertEqual({row[field_indexes["job_id"]] for row in result["values"]}, {"NA"})

    def test_missing_or_malformed_feedback_ranges_fail(self):
        missing_range = self.range_map.copy()
        del missing_range["live_amps"]
        with self.assertRaisesRegex(ValueError, "live_amps"):
            cloud_ingest.build_varied_template(make_template(), missing_range, rng=random.Random(1))

        malformed_range = self.range_map.copy()
        malformed_range["live_amps"] = dict(malformed_range["live_amps"])
        malformed_range["live_amps"]["Probable Range"] = "unknown"
        with self.assertRaisesRegex(ValueError, "live_amps"):
            cloud_ingest.build_varied_template(make_template(), malformed_range, rng=random.Random(1))

    def test_incompatible_schema_type_fails(self):
        template = make_template()
        template["schema"]["live_wfs"] = "f32"
        with self.assertRaisesRegex(ValueError, "live_wfs"):
            cloud_ingest.build_varied_template(template, self.range_map, rng=random.Random(1))

    def test_time_sequence_cannot_overflow_unsigned_schema_type(self):
        template = make_template()
        arc_time_index = list(SCHEMA).index("arc_time")
        template["values"][0][arc_time_index] = (1 << 32) - 5
        with self.assertRaisesRegex(ValueError, "arc_time"):
            cloud_ingest.build_varied_template(template, self.range_map, rng=random.Random(1))

    def test_private_template_is_owner_only(self):
        template = cloud_ingest.build_varied_template(
            make_template(), self.range_map, rng=random.Random(7)
        )
        with tempfile.TemporaryDirectory() as directory:
            path = cloud_ingest.write_private_template(template, directory)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            with open(path, encoding="utf-8") as file:
                self.assertEqual(len(json.load(file)["values"]), 50)

    def test_dry_run_does_not_transform_template(self):
        args = Namespace(probe=False, runs=1, force=False, dry_run=True, template=None)
        with (
            patch.object(cloud_ingest, "current_total", return_value=100),
            patch.object(cloud_ingest, "synthetic_count", return_value=0),
            patch.object(cloud_ingest, "print_plan"),
            patch.object(cloud_ingest, "build_varied_template") as transform,
        ):
            cloud_ingest.do_ingest(args, None, "index", None)
        transform.assert_not_called()

    def test_existing_synthetic_data_stops_before_transformation(self):
        args = Namespace(probe=False, runs=1, force=False, dry_run=False, template="unused.json")
        with (
            patch.object(cloud_ingest, "current_total", return_value=100),
            patch.object(cloud_ingest, "synthetic_count", return_value=1),
            patch.object(cloud_ingest, "build_varied_template") as transform,
        ):
            with self.assertRaises(SystemExit):
                cloud_ingest.do_ingest(args, None, "index", None)
        transform.assert_not_called()


if __name__ == "__main__":
    unittest.main()
