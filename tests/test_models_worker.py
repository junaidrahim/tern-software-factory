"""Deterministic Models worker tests; no live API, credentials, or persistent cache.

Run: python3 -m unittest discover -s tests -p test_models_worker.py
"""
from datetime import datetime, timezone
from email.utils import format_datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


SPEC = importlib.util.spec_from_file_location("models_worker", Path(__file__).resolve().parents[1] / "models" / "worker.py")
worker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = worker
SPEC.loader.exec_module(worker)


def model(identifier="one"):
    return {
        "id": identifier, "name": "Model " + identifier, "slug": "model-" + identifier,
        "release_date": "2026-09-01", "model_creator": {"id": "creator", "name": "Creator"},
        "evaluations": {"artificial_analysis_intelligence_index": 42.5,
                        "artificial_analysis_coding_index": 0,
                        "artificial_analysis_agentic_index": None},
        "pricing": {"price_1m_input_tokens": 0, "price_1m_output_tokens": 1.25},
        "performance": {"median_output_tokens_per_second": 91.5,
                        "median_time_to_first_token_seconds": None},
    }


def page(rows=None, *, current=1, total=1, size=1, version=4.1, tier="free"):
    return {"tier": tier, "intelligence_index_version": version,
            "pagination": {"page": current, "page_size": size, "total_pages": total, "has_more": current < total},
            "data": [model()] if rows is None else rows}


def response(payload):
    return 200, {"content-type": "application/json"}, json.dumps(payload).encode()


class ModelsWorkerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.cache = Path(self.directory.name) / "models" / "cache.json"
        self.key_path = Path(self.directory.name) / "artificial-analysis-api-key"
        self.now = 1_800_000_000.0
        self.secret = "private-api-key-do-not-print"
        self.environ = {"AA_API_KEY": self.secret}
        self.calls = []
        self.responses = [response(page())]

    def fetch(self, url, key):
        self.calls.append((url, key))
        result = self.responses.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    def call(self, action="refresh", **kwargs):
        return worker.execute({"action": action, "cache": str(self.cache), "key_path": str(self.key_path), **kwargs},
                              fetcher=self.fetch, clock=lambda: self.now, environ=self.environ)

    def seed(self):
        result = self.call()
        self.assertTrue(result["ok"], result)
        self.calls.clear()
        return result["snapshot"]

    def test_complete_free_pagination_and_normalization(self):
        self.responses = [response(page([model("one")], total=2)),
                          response(page([model("two")], current=2, total=2))]
        result = self.call()
        self.assertTrue(result["ok"], result)
        self.assertEqual([url for url, key in self.calls], [worker.ENDPOINT + "1", worker.ENDPOINT + "2"])
        self.assertTrue(all(key == self.secret for url, key in self.calls))
        self.assertEqual(result["snapshot"]["index_version"], "4.1")
        self.assertEqual(result["snapshot"]["fetched_at"], self.now)
        rows = result["snapshot"]["models"]
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["url"], "https://artificialanalysis.ai/models/model-one")
        self.assertEqual(rows[0]["creator_id"], "creator")
        self.assertEqual(rows[0]["coding"], 0)
        self.assertEqual(rows[0]["input_price"], 0)
        self.assertNotIn("agentic", rows[0])
        self.assertNotIn("ttft", rows[0])
        self.assertNotIn("context_window", rows[0])
        self.assertNotIn(self.secret, self.cache.read_text())
        self.assertNotIn(self.secret, json.dumps(result))

    def test_versioned_model_slugs_preserve_their_original_links(self):
        row = model()
        row["slug"] = "qwen3-0.6b-instruct"
        self.responses = [response(page([row]))]
        result = self.call()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["snapshot"]["models"][0]["url"],
                         "https://artificialanalysis.ai/models/qwen3-0.6b-instruct")

    def test_nulls_and_negative_indices_are_not_fabricated(self):
        row = model()
        row["release_date"] = None
        row["evaluations"]["artificial_analysis_intelligence_index"] = -7.5
        row["pricing"]["price_1m_output_tokens"] = None
        self.responses = [response(page([row]))]
        result = self.call()
        self.assertTrue(result["ok"], result)
        saved = result["snapshot"]["models"][0]
        self.assertEqual(saved["intelligence"], -7.5)
        self.assertNotIn("release_date", saved)
        self.assertNotIn("output_price", saved)

    def test_nullable_creator_remains_honestly_unknown_in_cache(self):
        row = model()
        row["model_creator"] = None
        self.responses = [response(page([row]))]
        result = self.call()
        self.assertTrue(result["ok"], result)
        saved = result["snapshot"]["models"][0]
        self.assertEqual(saved["creator"], "Unknown creator")
        self.assertEqual(saved["creator_id"], "")
        self.assertEqual(self.call("snapshot")["snapshot"], result["snapshot"])

    def test_pro_key_still_uses_only_free_endpoint(self):
        self.responses = [response(page(tier="pro"))]
        self.assertTrue(self.call()["ok"])
        self.assertEqual(self.calls[0][0], worker.ENDPOINT + "1")

    def test_snapshot_never_fetches_and_freshness_survives_worker_instances(self):
        snapshot = self.seed()
        self.now += 3600
        self.assertEqual(self.call("snapshot")["snapshot"], snapshot)
        fresh = self.call()
        self.assertEqual(fresh["snapshot"], snapshot)
        self.assertEqual(fresh["refresh_after_seconds"], worker.REFRESH_SECONDS - 3600)
        self.assertEqual(self.calls, [])
        self.responses = [response(page([model("new")]))]
        self.assertEqual(self.call(force=True)["snapshot"]["models"][0]["id"], "new")
        self.calls.clear()
        self.now += worker.REFRESH_SECONDS
        self.responses = [response(page([model("due")]))]
        self.assertEqual(self.call()["snapshot"]["models"][0]["id"], "due")
        self.assertEqual(len(self.calls), 1)

    def test_missing_key_keeps_empty_or_cached_snapshot_and_can_be_added_without_restart(self):
        self.environ.clear()
        result = self.call("snapshot")
        self.assertTrue(result["setup"])
        self.assertEqual(result["snapshot"], worker.empty_snapshot())
        self.assertEqual(self.calls, [])
        self.key_path.write_text(self.secret + "\n")
        snapshot = self.seed()
        self.key_path.unlink()
        result = self.call(force=True)
        self.assertTrue(result["setup"])
        self.assertEqual(result["snapshot"], snapshot)
        self.assertEqual(self.calls, [])

    def test_file_precedence_environment_fallback_and_key_recheck(self):
        self.key_path.write_text("file-key")
        self.assertTrue(self.call()["ok"])
        self.assertEqual(self.calls[-1][1], "file-key")
        self.key_path.write_text("replacement-key")
        self.responses = [response(page())]
        self.call(force=True)
        self.assertEqual(self.calls[-1][1], "replacement-key")
        self.key_path.unlink()
        self.environ["AA_API_KEY"] = "environment-key"
        self.responses = [response(page())]
        self.call(force=True)
        self.assertEqual(self.calls[-1][1], "environment-key")

    def test_invalid_existing_file_does_not_fall_back_to_environment(self):
        self.key_path.write_text("bad key")
        self.assertTrue(self.call()["setup"])
        self.assertEqual(self.calls, [])
        self.key_path.write_bytes(b"\xff")
        self.assertTrue(self.call()["setup"])
        self.assertEqual(self.calls, [])

    def test_save_key_is_atomic_private_and_preserves_cache_and_quota(self):
        snapshot = self.seed()
        self.responses = [(429, {"Retry-After": "600"}, b"")]
        self.call(force=True)
        self.calls.clear()
        before = self.cache.read_bytes()
        self.key_path.write_text("old-key")
        self.key_path.chmod(0o644)
        real_replace = os.replace
        observations = []

        def replace(source, target):
            self.assertEqual(Path(target).resolve(), self.key_path.resolve())
            self.assertEqual(Path(target).read_text(), "old-key")
            self.assertEqual(stat.S_IMODE(Path(source).stat().st_mode), 0o600)
            self.assertEqual(Path(source).read_text(), self.secret)
            observations.append(True)
            real_replace(source, target)

        request = {"action": "save_key", "cache": str(self.cache), "key_path": str(self.key_path),
                   "api_key": " \t" + self.secret + "\r\n"}
        with patch.object(worker.os, "replace", side_effect=replace):
            result = worker.execute(request, fetcher=self.fetch, clock=lambda: self.now, environ=self.environ)
        self.assertTrue(result["ok"])
        self.assertTrue(result["key_saved"])
        self.assertEqual(observations, [True])
        self.assertEqual(stat.S_IMODE(self.key_path.stat().st_mode), 0o600)
        self.assertEqual(self.key_path.read_text(), self.secret)
        self.assertEqual(result["snapshot"], snapshot)
        self.assertEqual(result["retry_at"], self.now + 600)
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(self.calls, [])
        self.assertNotIn("api_key", request)
        self.assertNotIn(self.secret, json.dumps(result))
        self.assertNotIn(self.secret, self.cache.read_text())
        self.assertFalse(self.call(force=True)["ok"], "Saving never resets the existing quota cooldown")
        self.assertEqual(self.calls, [])

    def test_save_key_creates_private_parent_without_cache_or_network(self):
        self.key_path = Path(self.directory.name) / "new-data" / "artificial-analysis-api-key"
        self.environ.clear()
        result = self.call("save_key", api_key="x" * worker.MAX_KEY_BYTES)
        self.assertTrue(result["key_saved"])
        self.assertTrue(result["ok"])
        self.assertEqual(stat.S_IMODE(self.key_path.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.key_path.stat().st_mode), 0o600)
        self.assertEqual(self.key_path.stat().st_size, worker.MAX_KEY_BYTES)
        self.assertFalse(self.cache.exists())
        self.assertEqual(self.calls, [])

    def test_save_key_rejects_invalid_values_without_overwriting(self):
        self.key_path.write_text("old-key")
        values = (None, False, 123, {}, [], "", " \t\r\n", "bad key", "bad\nkey", "bad\x00key",
                  "bad\x7fkey", "\u2603", "x" * (worker.MAX_KEY_BYTES + 1))
        for index, value in enumerate(values):
            with self.subTest(case=index):
                result = self.call("save_key", api_key=value)
                self.assertFalse(result["ok"])
                self.assertFalse(result["key_saved"])
                self.assertTrue(result["setup"])
                self.assertEqual(self.key_path.read_text(), "old-key")
                self.assertEqual(list(self.key_path.parent.iterdir()), [self.key_path])
                self.assertEqual(self.calls, [])
                self.assertNotIn(self.secret, json.dumps(result))

    def test_save_key_write_failures_preserve_old_key_and_remove_temporary(self):
        self.key_path.write_text("old-key")
        for operation in ("fchmod", "fsync", "replace"):
            with self.subTest(operation=operation):
                with patch.object(worker.os, operation, side_effect=OSError(self.secret)):
                    result = self.call("save_key", api_key=self.secret)
                self.assertFalse(result["ok"])
                self.assertFalse(result["key_saved"])
                self.assertEqual(self.key_path.read_text(), "old-key")
                self.assertEqual(list(self.key_path.parent.iterdir()), [self.key_path])
                self.assertNotIn(self.secret, json.dumps(result))
                self.assertEqual(self.calls, [])

    def test_save_key_succeeds_independently_of_corrupt_cache(self):
        self.cache.parent.mkdir()
        self.cache.write_text("not json")
        result = self.call("save_key", api_key=self.secret)
        self.assertTrue(result["key_saved"])
        self.assertTrue(result["ok"])
        self.assertIsNone(result["error"])
        self.assertEqual(self.cache.read_text(), "not json")
        self.assertEqual(self.calls, [])

    def test_save_key_rejects_repository_and_colliding_paths(self):
        for override in ({"key_path": str(worker.REPO / "not-created")},
                         {"cache": str(worker.REPO / "not-created")},
                         {"cache": str(self.key_path)}):
            result = self.call("save_key", api_key=self.secret, **override)
            self.assertFalse(result["key_saved"])
            self.assertFalse(self.key_path.exists())
            self.assertNotIn(self.secret, json.dumps(result))
        self.assertEqual(self.calls, [])

    def test_save_key_protocol_never_outputs_credentials_or_uses_network(self):
        request = {"action": "save_key", "api_key": self.secret,
                   "cache": str(self.cache), "key_path": str(self.key_path)}
        stdin = Mock(buffer=io.BytesIO(json.dumps(request).encode()))
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(worker.sys, "stdin", stdin), patch.object(worker.sys, "stdout", stdout), \
                patch.object(worker.sys, "stderr", stderr), patch.object(worker, "HTTPFetcher") as fetcher:
            worker.main()
        fetcher.assert_not_called()
        self.assertTrue(json.loads(stdout.getvalue())["key_saved"])
        self.assertNotIn(self.secret, stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")
        self.assertFalse(self.cache.exists())

    def test_invalid_local_key_is_setup_and_never_sent(self):
        for value in ("bad\nkey", "bad key", "\u2603", "x" * (worker.MAX_KEY_BYTES + 1)):
            with self.subTest(value_length=len(value)):
                self.environ["AA_API_KEY"] = value
                result = self.call(force=True)
                self.assertTrue(result["setup"])
                self.assertEqual(self.calls, [])
        self.environ.clear()
        self.key_path.write_bytes(b"\xff")
        self.assertTrue(self.call()["setup"])

    def test_auth_errors_and_transport_exceptions_never_echo_secrets(self):
        snapshot = self.seed()
        for failure in ((401, {}, self.secret.encode()), (403, {}, self.secret.encode()),
                        OSError("socket failed with " + self.secret),
                        (500, {}, self.secret.encode())):
            with self.subTest(kind=type(failure).__name__):
                self.responses = [failure]
                result = self.call(force=True)
                self.assertFalse(result["ok"])
                self.assertEqual(result["snapshot"], snapshot)
                self.assertEqual(result["setup"], isinstance(failure, tuple) and failure[0] in (401, 403))
                self.assertNotIn(self.secret, json.dumps(result))
                self.assertNotIn(self.secret, self.cache.read_text())

    def test_second_page_failure_never_commits_partial_snapshot(self):
        snapshot = self.seed()
        before = self.cache.read_bytes()
        self.responses = [response(page([model("new")], total=2)), (503, {}, b"unavailable")]
        result = self.call(force=True)
        self.assertFalse(result["ok"])
        self.assertEqual(result["snapshot"], snapshot)
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(len(self.calls), 2)

    def test_quota_cooldown_persists_and_manual_refresh_cannot_bypass_it(self):
        snapshot = self.seed()
        self.responses = [(429, {"Retry-After": "120", "X-RateLimit-Reset": str(self.now + 600)}, self.secret.encode())]
        result = self.call(force=True)
        self.assertFalse(result["ok"])
        self.assertEqual(result["retry_at"], self.now + 600)
        self.assertEqual(result["snapshot"], snapshot)
        self.calls.clear()
        self.now += 300
        self.assertEqual(self.call(force=True)["snapshot"], snapshot)
        self.assertEqual(self.call("snapshot")["retry_at"], self.now + 300)
        self.assertEqual(self.calls, [])
        self.now += 300
        self.responses = [response(page([model("after-reset")]))]
        self.assertTrue(self.call(force=True)["ok"])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(json.loads(self.cache.read_text())["retry_at"], 0)

    def test_quota_http_date_relative_reset_and_conservative_fallback(self):
        until = self.now + 1000
        formatted = format_datetime(datetime.fromtimestamp(until, timezone.utc), usegmt=True)
        self.assertEqual(worker.quota_reset({"Retry-After": formatted}, self.now), until)
        self.assertEqual(worker.quota_reset({"RateLimit-Reset": "300"}, self.now), self.now + 300)
        self.assertEqual(worker.quota_reset({"Retry-After": "nan", "X-RateLimit-Reset": "garbage"}, self.now), self.now + 86400)
        self.responses = [(429, {}, b"")]
        result = self.call()
        self.assertEqual(result["snapshot"], worker.empty_snapshot())
        self.assertEqual(result["retry_at"], self.now + 86400)
        self.assertTrue(self.cache.exists())

    def test_malformed_pages_and_models_are_rejected_without_cache_replacement(self):
        snapshot = self.seed()
        before = self.cache.read_bytes()
        cases = []
        for field, value in (("page", 2), ("page", True), ("page_size", 0), ("total_pages", 0),
                             ("total_pages", worker.MAX_PAGES + 1), ("has_more", True), ("has_more", 0)):
            payload = page()
            payload["pagination"][field] = value
            cases.append(payload)
        for field, value in (("data", {}), ("tier", "unknown"), ("intelligence_index_version", None),
                             ("intelligence_index_version", True), ("intelligence_index_version", float("inf"))):
            payload = page()
            payload[field] = value
            cases.append(payload)
        for field, value in (("name", ""), ("slug", "../secret"), ("release_date", "2026-02-31"),
                             ("model_creator", []), ("performance", {}), ("evaluations", None)):
            row = model()
            row[field] = value
            cases.append(page([row]))
        for value in (True, "42", float("nan"), float("inf")):
            row = model()
            row["evaluations"]["artificial_analysis_intelligence_index"] = value
            cases.append(page([row]))
        row = model()
        row["pricing"]["price_1m_input_tokens"] = -1
        cases.append(page([row]))
        for payload in cases:
            with self.subTest(payload=payload):
                self.responses = [response(payload)]
                result = self.call(force=True)
                self.assertFalse(result["ok"])
                self.assertEqual(result["snapshot"], snapshot)
                self.assertEqual(self.cache.read_bytes(), before)

    def test_inconsistent_or_duplicate_pagination_is_rejected(self):
        for second in (page([model("two")], current=2, total=2, version=4.2),
                       page([model("one")], current=2, total=2),
                       page([], current=2, total=2),
                       page([model("two")], current=2, total=3)):
            self.responses = [response(page(total=2)), response(second)]
            result = self.call(force=True)
            self.assertFalse(result["ok"])
            self.assertFalse(self.cache.exists())
        self.responses = [response(page([], total=2))]
        self.assertFalse(self.call(force=True)["ok"])

    def test_invalid_json_and_oversized_response_are_bounded(self):
        for body in (b"not json", b"\xff", b"x" * (worker.MAX_PAGE_BYTES + 1)):
            self.responses = [(200, {}, body)]
            result = self.call(force=True)
            self.assertFalse(result["ok"])
            self.assertFalse(self.cache.exists())

    def test_cache_permissions_atomic_replace_and_failed_write_preserve_old_data(self):
        snapshot = self.seed()
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.cache.parent.stat().st_mode), 0o700)
        before = self.cache.read_bytes()
        self.responses = [response(page([model("new")]))]
        with patch.object(worker.os, "replace", side_effect=OSError(self.secret)):
            result = self.call(force=True)
        self.assertFalse(result["ok"])
        self.assertEqual(result["snapshot"], snapshot)
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(list(self.cache.parent.iterdir()), [self.cache])
        self.assertNotIn(self.secret, json.dumps(result))
        real_replace = os.replace
        observations = []

        def replace(source, target):
            observations.append(json.loads(Path(source).read_bytes())["snapshot"]["models"][0]["id"])
            self.assertEqual(Path(target).read_bytes(), before)
            self.assertEqual(stat.S_IMODE(Path(source).stat().st_mode), 0o600)
            real_replace(source, target)

        self.responses = [response(page([model("complete")]))]
        with patch.object(worker.os, "replace", side_effect=replace):
            self.assertTrue(self.call(force=True)["ok"])
        self.assertEqual(observations, ["complete"])

    def test_corrupt_cache_can_be_refreshed_without_network_on_snapshot(self):
        self.cache.parent.mkdir()
        self.cache.write_text("not json")
        result = self.call("snapshot")
        self.assertFalse(result["ok"])
        self.assertEqual(result["snapshot"], worker.empty_snapshot())
        self.assertEqual(self.calls, [])
        self.assertTrue(self.call()["ok"])

    def test_repository_cache_and_credentials_are_rejected(self):
        for field in ("cache", "key_path"):
            result = self.call(**{field: str(worker.REPO / "not-created")})
            self.assertFalse(result["ok"])
            self.assertEqual(self.calls, [])
        result = self.call(cache=str(self.key_path))
        self.assertFalse(result["ok"])
        self.assertFalse(self.key_path.exists())

    def test_transport_is_fixed_https_and_does_not_follow_redirects(self):
        connection = Mock()
        remote = connection.getresponse.return_value
        remote.status = 302
        remote.getheaders.return_value = [("Location", "https://attacker.example/steal")]
        with patch.object(worker.http.client, "HTTPSConnection", return_value=connection) as constructor:
            result = worker.HTTPFetcher()(worker.ENDPOINT + "1", self.secret)
        constructor.assert_called_once_with("artificialanalysis.ai", timeout=worker.FETCH_SECONDS)
        connection.request.assert_called_once()
        args, kwargs = connection.request.call_args
        self.assertEqual(args, ("GET", "/api/v2/language/models/free?page=1"))
        self.assertEqual(kwargs["headers"]["x-api-key"], self.secret)
        remote.read.assert_not_called()
        connection.close.assert_called_once()
        self.assertEqual(result[0], 302)
        self.responses = [result]
        result = self.call()
        self.assertFalse(result["ok"])
        self.assertIn("Redirects are blocked", result["error"])
        self.assertNotIn(self.secret, json.dumps(result))
        with patch.object(worker.http.client, "HTTPSConnection") as constructor:
            with self.assertRaises(worker.ModelsError):
                worker.HTTPFetcher()("https://attacker.example/?page=1", self.secret)
            constructor.assert_not_called()

    def test_transport_limits_reads_and_rejects_compression(self):
        connection = Mock()
        remote = connection.getresponse.return_value
        remote.status = 200
        remote.getheaders.return_value = []
        remote.read.return_value = b"{}"
        with patch.object(worker.http.client, "HTTPSConnection", return_value=connection):
            self.assertEqual(worker.HTTPFetcher()(worker.ENDPOINT + "1", self.secret)[2], b"{}")
        remote.read.assert_called_once_with(worker.MAX_PAGE_BYTES + 1)
        remote.getheaders.return_value = [("Content-Encoding", "gzip")]
        with patch.object(worker.http.client, "HTTPSConnection", return_value=connection):
            with self.assertRaises(worker.ModelsError):
                worker.HTTPFetcher()(worker.ENDPOINT + "1", self.secret)

    def test_malformed_protocol_never_echoes_input(self):
        stdin = Mock(buffer=io.BytesIO(("invalid " + self.secret).encode()))
        stdout = io.StringIO()
        with patch.object(worker.sys, "stdin", stdin), patch.object(worker.sys, "stdout", stdout):
            worker.main()
        result = json.loads(stdout.getvalue())
        self.assertFalse(result["ok"])
        self.assertEqual(result["snapshot"], worker.empty_snapshot())
        self.assertNotIn(self.secret, stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
