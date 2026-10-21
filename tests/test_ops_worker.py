"""Consumer-facing agent snapshot tests using real temporary SQLite databases.

Run: python3 -m unittest discover -s tests -p test_ops_worker.py
"""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


WORKER_PATH = Path(__file__).resolve().parents[1] / "ops" / "worker.py"
SPEC = importlib.util.spec_from_file_location("ops_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)
MODEL_SCHEMA = "CREATE TABLE model_perf(model_key TEXT PRIMARY KEY, samples REAL, output_tokens REAL, gen_ms REAL, ttft_samples REAL, ttft_ms REAL, updated_at INTEGER)"
COMMAND_SCHEMA = "CREATE TABLE command_usage(name TEXT PRIMARY KEY, count INTEGER, last_used_at INTEGER)"


class OpsWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.path = self.base / "agent #1?.db"

    def database(self, models=(), commands=(), model_schema=MODEL_SCHEMA, command_schema=COMMAND_SCHEMA):
        connection = sqlite3.connect(self.path)
        try:
            if model_schema:
                connection.execute(model_schema)
            if command_schema:
                connection.execute(command_schema)
            connection.executemany("INSERT INTO model_perf VALUES (?, ?, ?, ?, ?, ?, ?)", models) if models else None
            connection.executemany("INSERT INTO command_usage VALUES (?, ?, ?)", commands) if commands else None
            connection.commit()
        finally:
            connection.close()

    def snapshot(self):
        result = worker.read_stats(self.path, now=1000)
        self.assertTrue(result["ok"], result)
        # Enforce strict finite JSON for all consumer-visible numbers.
        json.dumps(result, allow_nan=False)
        self.assertEqual(result["snapshot"]["generated_at"], 1000)
        return result["snapshot"]

    def test_weighted_ratios_are_not_lifetime_counts(self):
        self.database(models=[("model", 2.5, 250, 5000, 1.25, 500, 900)])
        snapshot = self.snapshot()
        self.assertEqual(snapshot["models"], [{
            "model_key": "model", "tokens_per_second": 50, "ttft_ms": 400,
            "avg_output_tokens": 100, "effective_samples": 2.5, "updated_at": 900,
        }])
        self.assertEqual(snapshot["summary"], {"measured_models": 1, "effective_samples": 2.5, "command_uses": 0})
        # Halving the weighted accumulators preserves all performance estimates.
        with sqlite3.connect(self.path) as connection:
            connection.execute("UPDATE model_perf SET samples=samples/2, output_tokens=output_tokens/2, gen_ms=gen_ms/2, ttft_samples=ttft_samples/2, ttft_ms=ttft_ms/2")
        halved = self.snapshot()["models"][0]
        for field in ("tokens_per_second", "ttft_ms", "avg_output_tokens"):
            self.assertEqual(halved[field], snapshot["models"][0][field])
        self.assertEqual(halved["effective_samples"], 1.25)

    def test_missing_invalid_and_zero_denominators_are_not_zero_measurements(self):
        self.database(models=[
            ("missing", None, None, None, None, None, None),
            ("denominators", 0, 10, 0, 0, 10, 1),
            ("invalid", -1, -20, float("inf"), -2, -3, -1),
            ("measured zero", 1, 0, 100, 1, 0, 2),
            ("overflow", 1e-300, 1e308, 1e-300, 1e-300, 1e308, 3),
        ])
        snapshot = self.snapshot()
        rows = {row["model_key"]: row for row in snapshot["models"]}
        for name in ("missing", "denominators", "invalid", "overflow"):
            for field in ("tokens_per_second", "ttft_ms", "avg_output_tokens"):
                self.assertIsNone(rows[name][field], (name, field))
        for field in ("tokens_per_second", "ttft_ms", "avg_output_tokens"):
            self.assertEqual(rows["measured zero"][field], 0)
        self.assertIsNone(snapshot["summary"]["effective_samples"])
        self.assertEqual(snapshot["summary"]["measured_models"], 1)
        self.assertTrue(snapshot["warnings"])

    def test_ordering_and_command_total_include_more_than_top_five(self):
        self.database(models=[
            ("z", 1, 1, 1, 1, 1, 20), ("a", 1, 1, 1, 1, 1, 20),
            ("new", 1, 1, 1, 1, 1, 30), ("unknown", 1, 1, 1, 1, 1, None),
        ], commands=[("z", 10, 1), ("a", 10, 2), ("b", 9, 3), ("c", 8, 4), ("d", 7, 5), ("e", 6, 6), ("f", 5, 7)])
        snapshot = self.snapshot()
        self.assertEqual([row["model_key"] for row in snapshot["models"]], ["new", "a", "z", "unknown"])
        self.assertEqual([row["name"] for row in snapshot["commands"]], ["a", "z", "b", "c", "d"])
        self.assertEqual(snapshot["summary"]["command_uses"], 55)

    def test_missing_model_table_preserves_commands(self):
        self.database(model_schema=None, commands=[("help", 3, 20)])
        snapshot = self.snapshot()
        self.assertEqual(snapshot["models"], [])
        self.assertIsNone(snapshot["summary"]["measured_models"])
        self.assertIsNone(snapshot["summary"]["effective_samples"])
        self.assertEqual(snapshot["summary"]["command_uses"], 3)
        self.assertTrue(snapshot["warnings"])

    def test_incompatible_command_columns_preserve_models(self):
        self.database(models=[("m", 2, 4, 10, 1, 5, 20)], command_schema="CREATE TABLE command_usage(name TEXT)")
        snapshot = self.snapshot()
        self.assertEqual(len(snapshot["models"]), 1)
        self.assertEqual(snapshot["commands"], [])
        self.assertIsNone(snapshot["summary"]["command_uses"])
        self.assertTrue(snapshot["warnings"])

    def test_no_compatible_tables_is_error_not_empty_success(self):
        self.database(model_schema=None, command_schema=None)
        self.assertFalse(worker.read_stats(self.path)["ok"])

    def test_empty_compatible_tables_are_genuine_zero(self):
        self.database()
        snapshot = self.snapshot()
        self.assertEqual(snapshot["models"], [])
        self.assertEqual(snapshot["commands"], [])
        self.assertEqual(snapshot["summary"], {"measured_models": 0, "effective_samples": 0, "command_uses": 0})
        self.assertEqual(snapshot["warnings"], [])

    def test_invalid_command_count_does_not_fabricate_total(self):
        self.database(commands=[("bad", -1, 10), ("text", "wrong", 10), ("good", 0, None)])
        snapshot = self.snapshot()
        self.assertEqual(snapshot["commands"], [{"name": "good", "count": 0, "last_used_at": None}])
        self.assertIsNone(snapshot["summary"]["command_uses"])
        self.assertTrue(snapshot["warnings"])

    def test_missing_database_is_not_created(self):
        result = worker.read_stats(self.path)
        self.assertFalse(result["ok"])
        self.assertTrue(result["setup"])
        self.assertFalse(self.path.exists())
        self.assertEqual(list(self.base.iterdir()), [])

    def test_read_only_database_and_private_tables_unchanged(self):
        self.database(models=[("m", 1, 1, 1, 1, 1, 10)])
        with sqlite3.connect(self.path) as connection:
            connection.execute("CREATE TABLE private_records(secret TEXT)")
            connection.execute("INSERT INTO private_records VALUES ('DO-NOT-DISCLOSE')")
        before = self.path.read_bytes()
        self.path.chmod(0o444)
        result = self.snapshot()
        self.assertEqual(self.path.read_bytes(), before)
        self.assertNotIn("DO-NOT-DISCLOSE", json.dumps(result))
        self.assertEqual(set(self.base.iterdir()), {self.path})

    def test_both_tables_share_consistent_snapshot(self):
        self.database(models=[("m", 1, 100, 1000, 1, 5, 10)], commands=[("help", 1, 10)])
        writer = sqlite3.connect(self.path)
        self.addCleanup(writer.close)
        writer.execute("PRAGMA journal_mode=WAL")
        connect = sqlite3.connect

        def open_reader(*args, **kwargs):
            reader = connect(*args, **kwargs)

            def before_query(sql):
                if sql == worker.COMMAND_SQL:
                    writer.execute("UPDATE model_perf SET output_tokens=200")
                    writer.execute("UPDATE command_usage SET count=2")
                    writer.commit()

            reader.set_trace_callback(before_query)
            return reader

        with patch.object(worker.sqlite3, "connect", side_effect=open_reader):
            snapshot = self.snapshot()
        self.assertEqual(snapshot["models"][0]["avg_output_tokens"], 100)
        self.assertEqual(snapshot["summary"]["command_uses"], 1)
        self.assertEqual(self.snapshot()["summary"]["command_uses"], 2)

    def test_malformed_database_has_safe_error(self):
        self.path.write_bytes(b"PRIVATE corrupt database data")
        before = self.path.read_bytes()
        result = worker.read_stats(self.path)
        self.assertFalse(result["ok"])
        self.assertNotIn("PRIVATE", result["error"])
        self.assertNotIn(str(self.path), result["error"])
        self.assertEqual(self.path.read_bytes(), before)

    def test_display_names_are_bounded_single_line_without_controls(self):
        self.database(models=[("\x1b\n\u202e" + "m" * 500, 1, 1, 1, 1, 1, 10)], commands=[("\x00\t\u2028help", 2, 10)])
        snapshot = self.snapshot()
        self.assertEqual(snapshot["models"][0]["model_key"], "m" * worker.MAX_NAME)
        self.assertEqual(snapshot["commands"][0]["name"], "help")

    def run_worker(self, payload):
        result = subprocess.run([sys.executable, str(WORKER_PATH)], input=payload, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env={**os.environ, "HOME": str(self.base)}, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(len(result.stdout.splitlines()), 1)
        return json.loads(result.stdout)

    def test_stdio_snapshot_uses_host_path_not_request_path(self):
        self.database(commands=[("help", 3, 20)])
        host_path = self.base / ".omp" / "agent" / "agent.db"
        host_path.parent.mkdir(parents=True)
        self.path.rename(host_path)
        result = self.run_worker(b'{"action":"snapshot","path":"/not/allowed"}')
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["snapshot"]["summary"]["command_uses"], 3)
        self.assertFalse(result["snapshot"]["activity"]["available"])
        self.assertIsNone(result["snapshot"]["activity"]["sessions"])

    def host_history(self):
        root = self.base / ".omp" / "agent" / "sessions" / "project"
        root.mkdir(parents=True)
        path = root / "root.jsonl"
        path.write_text(json.dumps({"type": "session", "version": 3, "id": "root"}) + "\n" +
                        json.dumps({"type": "message", "id": "message", "timestamp": "2026-01-01T00:00:00Z",
                                    "message": {"role": "assistant", "provider": "provider", "responseId": "response",
                                                "content": "PRIVATE transcript", "usage": {
                                                    "input": 310, "output": 68, "cacheRead": 7424,
                                                    "cacheWrite": 0, "totalTokens": 7802}}}) + "\n")
        return path

    def test_stdio_combines_recorded_history_with_existing_performance(self):
        self.database(models=[("model", 2, 100, 1000, 1, 5, 20)], commands=[("help", 3, 20)])
        transcript = self.host_history()
        host_path = transcript.parents[2] / "agent.db"
        self.path.rename(host_path)
        before = transcript.read_bytes()
        result = self.run_worker(b'{"action":"snapshot"}')
        self.assertTrue(result["ok"], result)
        snapshot = result["snapshot"]
        self.assertEqual(snapshot["models"][0]["tokens_per_second"], 100)
        self.assertEqual(snapshot["summary"], {"measured_models": 1, "effective_samples": 2, "command_uses": 3})
        self.assertEqual(snapshot["activity"], {
            "available": True, "partial": False, "sessions": 1, "subagents": 0, "responses": 1,
            "tokens": {"input": 310, "output": 68, "cache_read": 7424, "cache_write": 0, "total": 7802},
            "warnings": [],
        })
        self.assertEqual(transcript.read_bytes(), before)
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_history_survives_missing_or_malformed_database_without_false_zero_summaries(self):
        transcript = self.host_history()
        host_path = transcript.parents[2] / "agent.db"
        for malformed in (False, True):
            with self.subTest(malformed=malformed):
                if malformed:
                    host_path.write_bytes(b"PRIVATE malformed database")
                result = self.run_worker(b'{"action":"snapshot"}')
                self.assertTrue(result["ok"], result)
                snapshot = result["snapshot"]
                self.assertEqual(snapshot["activity"]["tokens"]["total"], 7802)
                self.assertEqual(snapshot["models"], [])
                self.assertEqual(snapshot["commands"], [])
                self.assertEqual(snapshot["summary"], {"measured_models": None, "effective_samples": None, "command_uses": None})
                self.assertTrue(snapshot["warnings"])
                self.assertNotIn("PRIVATE", json.dumps(result))
                self.assertEqual(host_path.exists(), malformed)

    def test_partial_history_remains_visible_alongside_performance(self):
        self.database(commands=[("help", 3, 20)])
        transcript = self.host_history()
        self.path.rename(transcript.parents[2] / "agent.db")
        with transcript.open("a") as stream:
            stream.write('{"PRIVATE unfinished')
        result = self.run_worker(b'{"action":"snapshot"}')
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["snapshot"]["summary"]["command_uses"], 3)
        self.assertTrue(result["snapshot"]["activity"]["partial"])
        self.assertEqual(result["snapshot"]["activity"]["responses"], 1)
        self.assertEqual(result["snapshot"]["activity"]["tokens"]["total"], 7802)
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_missing_database_and_history_return_safe_actionable_failure(self):
        result = self.run_worker(b'{"action":"snapshot"}')
        self.assertFalse(result["ok"])
        self.assertTrue(result["setup"])
        self.assertFalse(result["activity"]["available"])
        self.assertIsNone(result["activity"]["sessions"])
        self.assertIn("history", result["error"])
        self.assertFalse((self.base / ".omp").exists())

    def test_stdio_rejects_invalid_or_oversized_requests(self):
        for payload in (b"{", b"[]", b'{"action":"write"}', b"x" * (worker.MAX_REQUEST + 1)):
            with self.subTest(payload=payload[:40]):
                self.assertFalse(self.run_worker(payload)["ok"])
        self.assertFalse((self.base / ".omp").exists())


if __name__ == "__main__":
    unittest.main()
