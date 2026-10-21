"""Consumer-visible coverage for retained session counters (no host data used)."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HISTORY_PATH = Path(__file__).resolve().parents[1] / "ops" / "history.py"
SPEC = importlib.util.spec_from_file_location("ops_history", HISTORY_PATH)
history = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(history)


def session(identifier, **fields):
    return {"type": "session", "version": 3, "id": identifier, **fields}


def response(identifier, usage=None, response_id=None, provider="provider", timestamp="2026-01-01T00:00:00Z"):
    message = {"role": "assistant", "provider": provider, "model": "model", "content": "PRIVATE-CONTENT"}
    if usage is not None:
        message["usage"] = usage
    if response_id is not None:
        message["responseId"] = response_id
    return {"type": "message", "id": identifier, "timestamp": timestamp, "message": message}


def usage(input=10, output=2, cache_read=4, cache_write=1, total=17):
    return {"input": input, "output": output, "cacheRead": cache_read, "cacheWrite": cache_write, "totalTokens": total}


class OpsHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "sessions"
        self.root.mkdir()

    def transcript(self, name, entries):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
        return path

    def snapshot(self):
        result = history.read_history(self.root)
        self.assertTrue(result["available"], result)
        encoded = json.dumps(result, allow_nan=False)
        self.assertNotIn("PRIVATE", encoded)
        self.assertNotIn(str(self.root), encoded)
        self.assertLess(len(result["warnings"]), 10)
        return result

    def test_forks_copies_and_nested_subagents_count_unique_runs_and_responses(self):
        shared = response("original", usage(), "response-1")
        self.transcript("project/root.jsonl", [{"type": "title", "title": "PRIVATE-TITLE"}, session("root"), shared])
        copied = response("different-entry-id", usage(), "response-1")
        self.transcript("project/fork.jsonl", [session("fork", parentSession="PRIVATE-parent"), copied, response("new", usage(), "response-2")])
        self.transcript("project/duplicate.jsonl", [session("root"), shared, response("extra", usage(), "response-3")])
        self.transcript("project/root/child.jsonl", [session("child", parentSession="PRIVATE-parent"), shared, response("child-response", usage(), "response-4")])
        self.transcript("project/root/child/grandchild.jsonl", [session("grandchild"), response("grandchild-response", usage(), "response-5")])
        self.transcript("project/root/duplicate-child.jsonl", [session("child"), shared])
        result = self.snapshot()
        self.assertFalse(result["partial"])
        self.assertEqual((result["sessions"], result["subagents"], result["responses"]), (2, 2, 5))
        self.assertEqual(result["tokens"], {"input": 50, "output": 10, "cache_read": 20, "cache_write": 5, "total": 85})

    def test_response_identity_uses_provider_and_fallback_entry_metadata(self):
        entries = [session("root"), response("a", usage(), "same", "one"), response("b", usage(), "same", "two"),
                   response("fallback", usage()), response("fallback", usage()),
                   response("fallback", usage(), timestamp="2026-01-02T00:00:00Z")]
        self.transcript("project/root.jsonl", entries)
        self.assertEqual(self.snapshot()["responses"], 4)

    def test_provider_total_is_authoritative_and_component_sum_is_fallback(self):
        self.transcript("project/root.jsonl", [session("root"), response("one", usage(total=100)),
                        response("two", {"input": 310, "output": 68, "cacheRead": 7424, "cacheWrite": 0}),
                        response("three", usage(input=0, output=0, cache_read=0, cache_write=0, total=0))])
        result = self.snapshot()
        self.assertFalse(result["partial"])
        self.assertEqual(result["tokens"], {"input": 320, "output": 70, "cache_read": 7428, "cache_write": 1, "total": 7902})

    def test_missing_components_remain_unavailable_but_recorded_total_survives(self):
        self.transcript("project/root.jsonl", [session("root"), response("one", usage()),
                        response("two", {"input": 3, "output": 0, "totalTokens": 5})])
        result = self.snapshot()
        self.assertTrue(result["partial"])
        self.assertEqual(result["responses"], 2)
        self.assertEqual(result["tokens"], {"input": 13, "output": 2, "cache_read": None, "cache_write": None, "total": 22})

    def test_partial_components_cannot_fabricate_total(self):
        self.transcript("project/root.jsonl", [session("root"), response("one", {"input": 3, "output": 2})])
        result = self.snapshot()
        self.assertIsNone(result["tokens"]["total"])
        self.assertEqual(result["tokens"]["input"], 3)
        self.assertTrue(result["partial"])

    def test_invalid_measurements_are_not_counts_or_zero(self):
        self.transcript("project/root.jsonl", [session("root"),
                        response("one", usage(input=True, output=-1, cache_read=1.5, cache_write=float("inf"), total=8)),
                        response("two", usage(total=float("nan"))),
                        response("three", {"totalTokens": "19"}), response("four"),
                        response("five", {"cost": {"total": 0.5}})])
        result = self.snapshot()
        self.assertEqual(result["responses"], 2)
        self.assertEqual(result["tokens"], {"input": None, "output": None, "cache_read": None, "cache_write": None, "total": 25})
        self.assertTrue(any("not recorded for all" in warning for warning in result["warnings"]))

    def test_integral_float_measurements_are_exact_integer_counts(self):
        self.transcript("project/root.jsonl", [session("root"), response("one", usage(input=10.0, total=17.0))])
        result = self.snapshot()
        self.assertIs(type(result["tokens"]["input"]), int)
        self.assertIs(type(result["tokens"]["total"]), int)
        self.assertFalse(result["partial"])

    def test_duplicate_missing_usage_is_reconciled_without_double_counting(self):
        self.transcript("project/root.jsonl", [session("root"), response("one", response_id="same"),
                        response("two", {"totalTokens": 17}, "same"), response("three", usage(), "same")])
        result = self.snapshot()
        self.assertEqual(result["responses"], 1)
        self.assertEqual(result["tokens"]["input"], 10)
        self.assertFalse(result["partial"])

    def test_conflicting_copied_measurements_are_unavailable(self):
        self.transcript("project/root.jsonl", [session("root"), response("one", usage(), "same"),
                        response("two", usage(input=12), "same"), response("three", usage(), "same")])
        result = self.snapshot()
        self.assertEqual(result["responses"], 1)
        self.assertIsNone(result["tokens"]["input"])
        self.assertEqual(result["tokens"]["total"], 17)
        self.assertTrue(result["partial"])

    def test_in_progress_final_line_is_partial_then_recovers_when_finished(self):
        path = self.transcript("project/root.jsonl", [session("root"), response("one", usage())])
        pending = json.dumps(response("two", usage()))
        with path.open("a") as stream:
            stream.write(pending[:-5])
        partial = self.snapshot()
        self.assertTrue(partial["partial"])
        self.assertEqual(partial["responses"], 1)
        with path.open("a") as stream:
            stream.write(pending[-5:] + "\n")
        complete = self.snapshot()
        self.assertFalse(complete["partial"])
        self.assertEqual(complete["responses"], 2)

    def test_malformed_and_invalid_utf8_lines_do_not_hide_later_usage(self):
        path = self.transcript("project/root.jsonl", [session("root")])
        with path.open("ab") as stream:
            stream.write(b'{"PRIVATE-malformed"\n\xff\n')
            stream.write((json.dumps(response("one", usage())) + "\n").encode())
        result = self.snapshot()
        self.assertTrue(result["partial"])
        self.assertEqual(result["responses"], 1)

    def test_invalid_headers_and_unidentifiable_responses_report_partial_coverage(self):
        self.transcript("project/invalid.jsonl", [session(None), response("ignored", usage())])
        missing_identifier = response(None, usage())
        self.transcript("project/root.jsonl", [session("root"), {"type": "message", "message": "PRIVATE malformed"},
                        missing_identifier, response("good", usage())])
        result = self.snapshot()
        self.assertTrue(result["partial"])
        self.assertEqual((result["sessions"], result["responses"]), (1, 1))
        self.assertEqual(result["tokens"]["total"], 17)
        self.assertTrue(any("identifiers" in warning for warning in result["warnings"]))

    def test_non_session_artifacts_and_user_messages_do_not_count(self):
        self.transcript("project/artifact.jsonl", [response("artifact", usage()), session("not-a-header")])
        self.transcript("project/title.jsonl", [{"type": "title", "title": "PRIVATE-TITLE"}])
        self.transcript("project/root.jsonl", [session("root"), {"type": "message", "message": {"role": "user", "usage": usage()}}])
        result = self.snapshot()
        self.assertEqual((result["sessions"], result["subagents"], result["responses"]), (1, 0, 0))
        self.assertEqual(set(result["tokens"].values()), {0})
        self.assertFalse(result["partial"])

    def test_missing_and_non_directory_roots_are_unavailable_not_zero(self):
        file = self.base / "not-directory"
        file.write_text("PRIVATE")
        for root in (self.base / "missing", file):
            result = history.read_history(root)
            self.assertFalse(result["available"])
            self.assertIsNone(result["sessions"])
            self.assertIsNone(result["responses"])
            self.assertEqual(set(result["tokens"].values()), {None})
            self.assertTrue(result["warnings"])
            self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertFalse((self.base / "missing").exists())

    def test_existing_empty_root_has_genuine_zero_counts(self):
        result = self.snapshot()
        self.assertFalse(result["partial"])
        self.assertEqual((result["sessions"], result["subagents"], result["responses"]), (0, 0, 0))
        self.assertEqual(set(result["tokens"].values()), {0})

    def test_unreadable_root_is_unavailable_and_unreadable_file_is_partial(self):
        self.transcript("project/good.jsonl", [session("good"), response("one", usage())])
        self.transcript("project/private.jsonl", [session("hidden"), response("two", usage())])
        original = os.open

        def deny_file(path, *args, **kwargs):
            if path == "private.jsonl":
                raise PermissionError("PRIVATE access failure")
            return original(path, *args, **kwargs)

        with patch.object(history.os, "open", side_effect=deny_file):
            result = self.snapshot()
        self.assertTrue(result["partial"])
        self.assertEqual((result["sessions"], result["responses"]), (1, 1))
        with patch.object(history.os, "open", side_effect=PermissionError("PRIVATE root")):
            unavailable = history.read_history(self.root)
        self.assertFalse(unavailable["available"])
        self.assertIsNone(unavailable["sessions"])
        self.assertNotIn("PRIVATE", json.dumps(unavailable))

    def test_symlinked_files_and_directories_never_escape_root(self):
        outside = self.base / "outside"
        outside.mkdir()
        path = outside / "private.jsonl"
        path.write_text(json.dumps(session("outside")) + "\n" + json.dumps(response("one", usage())) + "\n")
        (self.root / "linked.jsonl").symlink_to(path)
        (self.root / "linked-directory").symlink_to(outside, target_is_directory=True)
        result = self.snapshot()
        self.assertTrue(result["partial"])
        self.assertEqual((result["sessions"], result["responses"]), (0, 0))
        root_link = self.base / "root-link"
        root_link.symlink_to(self.root, target_is_directory=True)
        self.assertFalse(history.read_history(root_link)["available"])

    def test_history_is_read_only_and_private_data_never_leaves_result(self):
        path = self.transcript("project/root.jsonl", [{"type": "title", "title": "PRIVATE-TITLE"}, session("root", credentials="PRIVATE-SECRET"), response("one", usage())])
        before = path.read_bytes()
        path.chmod(0o444)
        files = set(self.base.rglob("*"))
        result = self.snapshot()
        self.assertEqual(result["responses"], 1)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(set(self.base.rglob("*")), files)


if __name__ == "__main__":
    unittest.main()
