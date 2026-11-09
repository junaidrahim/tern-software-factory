"""Read-only GitHub worker tests: real local Git fixtures, no network calls."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


WORKER_PATH = Path(__file__).resolve().parents[1] / "github" / "worker.py"
SPEC = importlib.util.spec_from_file_location("github_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


def pull(number, *, identity="owner/repo", updated="2026-10-18T12:00:00Z", **extra):
    row = {
        "number": number, "title": f"Change {number} 雪", "url": f"https://github.com/{identity}/pull/{number}",
        "author": {"login": "contributor"}, "isDraft": False,
        "headRefName": "feature/雪", "baseRefName": "main", "updatedAt": updated,
    }
    row.update(extra)
    return row


def endpoint(identity, after=None):
    return f"pulls {identity} after={after}"


def connection(nodes, *, total=None, cursor=None):
    return {"data": {"repository": {"pullRequests": {
        "totalCount": len(nodes) if total is None else total,
        "pageInfo": {"hasNextPage": cursor is not None, "endCursor": cursor}, "nodes": nodes,
    }}}}


class FakeCommands:
    """Inject gh responses while letting read-only Git commands use real fixtures."""
    def __init__(self, responses=None):
        self.responses = {"user": {"login": "fixture-user"}, **(responses or {})}
        self.calls = []

    @staticmethod
    def request(arguments):
        if arguments[1:5] == ["api", "--hostname", "github.com", "user"] and len(arguments) == 5:
            return "user"
        if arguments[1:5] != ["api", "graphql", "--hostname", "github.com"]:
            raise AssertionError(f"Unexpected gh command: {arguments}")
        fields = dict(value.split("=", 1) for flag, value in zip(arguments[5::2], arguments[6::2]))
        if fields.get("first") != str(worker.PAGE_SIZE) or "pullRequests" not in fields.get("query", ""):
            raise AssertionError(f"Unexpected GitHub query: {arguments}")
        return endpoint(f"{fields['owner']}/{fields['name']}", fields.get("after"))

    def __call__(self, arguments, **kwargs):
        self.calls.append((arguments, kwargs))
        if arguments[0] != "/fixture/gh":
            return subprocess.run(arguments, **kwargs)
        url = self.request(arguments)
        if url not in self.responses:
            raise AssertionError(f"Unexpected GitHub request: {url}")
        response = self.responses[url]
        if isinstance(response, Exception):
            raise response
        if isinstance(response, subprocess.CompletedProcess):
            return response
        if isinstance(response, list):
            response = connection(response)
        return subprocess.CompletedProcess(arguments, 0, json.dumps(response).encode(), b"")

    def api_calls(self):
        return [self.request(args) for args, kwargs in self.calls if args[0] == "/fixture/gh"]


class RemoteTests(unittest.TestCase):
    def test_supported_remote_forms(self):
        for value in (
            "https://github.com/Owner/repo.git", "https://github.com/Owner/repo/",
            "https://github.com:443/Owner/repo.git", "https://user:secret@github.com/Owner/repo.git",
            "ssh://git@github.com/Owner/repo.git", "ssh://git@github.com:22/Owner/repo",
            "git@github.com:Owner/repo.git", "git@GITHUB.COM:Owner/repo.git",
        ):
            with self.subTest(value=value):
                self.assertEqual(worker.remote_repository(value), "Owner/repo")
        self.assertEqual(worker.remote_repository("https://github.com/a/repo.name.git.git"), "a/repo.name.git")

    def test_rejects_non_github_and_ambiguous_unsafe_remote_urls(self):
        for value in (
            None, "", "https://gitlab.com/owner/repo", "https://github.com.evil.test/owner/repo",
            "https://github.com@evil.test/owner/repo", "https://evil.test/github.com/owner/repo",
            "http://github.com/owner/repo", "file:///owner/repo", "/local/repo", "../repo",
            "ssh://other@github.com/owner/repo", "ssh://git:secret@github.com/owner/repo",
            "ssh://git@github.com:2222/owner/repo", "https://github.com:444/owner/repo",
            "https://github.com:bad/owner/repo", "https://[github.com/owner/repo",
            "https://github.com/owner/repo?x=y", "https://github.com/owner/repo#frag",
            "https://github.com/owner/repo?", "https://github.com/owner/repo#",
            "git@github.com:owner/repo?token=secret", "git@github.com:/owner/repo",
            "https://github.com/owner/repo/extra", "https://github.com//owner/repo",
            "https://github.com/owner/%72epo", "https://github.com/owner/..",
            "https://github.com/owner/.git", "https://github.com/-owner/repo",
            "https://github.com/owner/repo\n", "https://github.com/owner/re po",
            "https://github.com/owner/repo\\more", "https://github.com/owner/repo\0",
        ):
            with self.subTest(value=value):
                self.assertIsNone(worker.remote_repository(value))

    def test_known_install_fallback_and_path_precedence(self):
        with mock.patch.object(worker.shutil, "which", return_value="/custom/bin/gh"):
            self.assertEqual(worker.resolve_gh(), "/custom/bin/gh")
        with mock.patch.object(worker.shutil, "which", return_value=None), mock.patch.object(worker.os.path, "isfile", return_value=True), mock.patch.object(worker.os, "access", side_effect=lambda path, mode: path == "/usr/local/bin/gh"):
            self.assertEqual(worker.resolve_gh(), "/usr/local/bin/gh")
        with mock.patch.object(worker.shutil, "which", return_value=None), mock.patch.object(worker.os.path, "isfile", return_value=False):
            self.assertIsNone(worker.resolve_gh())

    def test_pr_links_reject_unsafe_or_unrelated_targets(self):
        for url in (
            "javascript:alert(1)", "http://github.com/owner/repo/pull/1",
            "https://github.com.evil.test/owner/repo/pull/1", "https://user:secret@github.com/owner/repo/pull/1",
            "https://github.com:443/owner/repo/pull/1", "https://github.com/other/repo/pull/1",
            "https://github.com/owner/repo/pull/2", "https://github.com/owner/repo/pull/1?secret=x",
            "https://github.com/owner/repo/pull/1#", "https://github.com/owner/repo/pull/1\n", None,
        ):
            with self.subTest(url=url), self.assertRaises(worker.GitHubError):
                worker.pull_request(pull(1, url=url), "owner/repo")

    def test_pr_schema_and_deleted_author(self):
        row = worker.pull_request(pull(3, author=None, isDraft=True), "owner/repo")
        self.assertEqual(row["author"], "")
        self.assertTrue(row["draft"])
        self.assertEqual(row["head"], "feature/雪")
        for overrides in ({"number": True}, {"number": 0}, {"title": None}, {"isDraft": "false"}, {"headRefName": None}, {"updatedAt": "yesterday"}, {"updatedAt": "2026-10-18T12:00:00"}):
            with self.subTest(overrides=overrides), self.assertRaises(worker.GitHubError):
                worker.pull_request(pull(1, **overrides) if "number" not in overrides else {**pull(1), **overrides}, "owner/repo")


@unittest.skipUnless(shutil.which("git"), "Git is required for local repository fixtures")
class GitHubWorkerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "root 雪 with spaces"
        self.root.mkdir()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                        GIT_TERMINAL_PROMPT="0")
        self.environment = mock.patch.dict(os.environ, self.env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        gh = mock.patch.object(worker, "resolve_gh", return_value="/fixture/gh")
        gh.start()
        self.addCleanup(gh.stop)

    def git(self, directory, *arguments):
        return subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull, "-C", str(directory), *arguments],
            env=self.env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        ).stdout

    def repository(self, name, remotes=None):
        path = self.root / name
        path.mkdir(parents=True)
        self.git(path, "init", "--initial-branch=main")
        self.git(path, "commit", "--allow-empty", "-m", "Fixture")
        for remote, url in (remotes or {}).items():
            self.git(path, "remote", "add", remote, url)
        return path

    def execute(self, responses=None, *, root=None, commands=None):
        commands = commands or FakeCommands(responses)
        result = worker.execute({"root": str(self.root if root is None else root)}, runner=commands)
        return result, commands

    def test_real_repositories_remote_precedence_zero_pr_and_sorting(self):
        self.repository("a", {"origin": "git@github.com:Zoo/repo.git", "upstream": "git@github.com:no/thanks.git"})
        self.repository("b", {"origin": "https://gitlab.com/no/repo", "upstream": "ssh://git@github.com/Alpha/repo.git", "a": "git@github.com:no/thanks.git"})
        self.repository("c", {"zzz": "git@github.com:no/thanks.git", "aaa": "https://github.com/Beta/repo.git"})
        self.repository("d", {"origin": "https://gitlab.com/no/repo"})
        self.repository("e")
        result, commands = self.execute({endpoint(identity): [] for identity in ("Zoo/repo", "Alpha/repo", "Beta/repo")})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["root"], str(self.root))
        self.assertEqual([repo["name"] for repo in result["repos"]], ["Alpha/repo", "Beta/repo", "Zoo/repo"])
        self.assertTrue(all(repo["prs"] == [] and "error" not in repo for repo in result["repos"]))
        self.assertEqual(len(commands.api_calls()), 4)

    def test_clones_worktrees_deduplicated_and_local_paths_unchanged(self):
        main = self.repository("a main 雪", {"origin": "https://user:secret@github.com/Owner/repo.git"})
        self.repository("b clone", {"origin": "git@github.com:owner/REPO.git"})
        self.git(main, "worktree", "add", "-b", "topic", str(self.root / "c linked 雪"))
        before = self.git(main, "status", "--porcelain"), (main / ".git" / "config").read_bytes()
        result, commands = self.execute({endpoint("Owner/repo"): [pull(1, identity="Owner/repo")]})
        self.assertTrue(result["ok"], result)
        self.assertEqual(len(result["repos"]), 1)
        row = result["repos"][0]
        self.assertEqual(row["path"], str(main))
        self.assertEqual(row["url"], "https://github.com/Owner/repo")
        self.assertEqual(row["prs"][0]["url"], "https://github.com/Owner/repo/pull/1")
        self.assertNotIn("secret", json.dumps(result))
        self.assertEqual(commands.api_calls().count(endpoint("Owner/repo")), 1)
        self.assertEqual(before, (self.git(main, "status", "--porcelain"), (main / ".git" / "config").read_bytes()))

    def test_malformed_github_remote_warns_without_leaking_credentials(self):
        credential = "gh-token-fixture-do-not-expose"
        self.repository("unsafe", {"origin": "https://secret@github.com/owner/repo?token=" + credential})
        result, commands = self.execute()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["repos"], [])
        self.assertIn("malformed", " ".join(result["warnings"]))
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn(credential, json.dumps(result))

    def test_refresh_loads_only_first_page_with_total_and_cursor(self):
        self.repository("repo", {"origin": "git@github.com:owner/repo"})
        first = [pull(number) for number in range(1, 26)] + [pull(3)]
        result, commands = self.execute({endpoint("owner/repo"): connection(first, total=4888, cursor="Y3Vyc29yOjI1")})
        self.assertTrue(result["ok"], result)
        row = result["repos"][0]
        self.assertEqual([pr["number"] for pr in row["prs"]], list(range(1, 26)), "Server order kept; duplicates dropped")
        self.assertEqual((row["total"], row["cursor"]), (4888, "Y3Vyc29yOjI1"))
        self.assertEqual(commands.api_calls(), ["user", endpoint("owner/repo")])

    def test_last_page_has_no_cursor(self):
        self.repository("repo", {"origin": "git@github.com:owner/repo"})
        result, commands = self.execute({endpoint("owner/repo"): [pull(1)]})
        self.assertEqual(result["repos"][0]["total"], 1)
        self.assertNotIn("cursor", result["repos"][0])

    def test_next_page_request_skips_discovery_and_authentication(self):
        commands = FakeCommands({endpoint("owner/repo", "Y3Vyc29yOjI1"): connection([pull(26)], total=26)})
        result = worker.execute({"repo": "owner/repo", "after": "Y3Vyc29yOjI1"}, runner=commands)
        self.assertEqual(result, {"ok": True, "repo": "owner/repo", "prs": [worker.pull_request(pull(26), "owner/repo")], "total": 26})
        self.assertEqual(commands.api_calls(), [endpoint("owner/repo", "Y3Vyc29yOjI1")])
        for request in ({"repo": "../repo", "after": "abc"}, {"repo": "owner/repo", "after": "a b"}, {"repo": "owner/repo"},
                        {"repo": "https://github.com/owner/repo", "after": "abc"}, {"repo": "owner/repo", "after": "x" * 513}):
            with self.subTest(request=request):
                commands = FakeCommands()
                result = worker.execute(request, runner=commands)
                self.assertFalse(result["ok"])
                self.assertEqual(commands.calls, [])
        failure = FakeCommands({endpoint("owner/repo", "abc"): subprocess.CompletedProcess([], 1, b"", b"HTTP 403 secret")})
        result = worker.execute({"repo": "owner/repo", "after": "abc"}, runner=failure)
        self.assertFalse(result["ok"])
        self.assertIn("denied", result["error"])
        self.assertNotIn("secret", json.dumps(result))

    def test_repository_access_failures_remain_visible(self):
        self.repository("repo", {"origin": "git@github.com:owner/repo"})
        for detail, message in ((b"HTTP 403 secret", "denied"), (b"gh: Could not resolve to a Repository with the name 'secret'.", "lacks access")):
            with self.subTest(detail=detail):
                result, commands = self.execute({endpoint("owner/repo"): subprocess.CompletedProcess([], 1, b"", detail)})
                self.assertTrue(result["ok"], result)
                self.assertEqual(result["repos"][0]["prs"], [])
                self.assertIn(message, result["repos"][0]["error"])
                self.assertNotIn("secret", json.dumps(result))

    def test_unreadable_local_remotes_warn_without_hiding_other_repositories(self):
        unreadable = self.repository("a", {"origin": "git@github.com:owner/a"})
        self.repository("b", {"origin": "git@github.com:owner/b"})
        commands = FakeCommands({endpoint("owner/b"): []})
        def failed_remote(arguments, **kwargs):
            if str(unreadable) in arguments:
                return subprocess.CompletedProcess(arguments, 128, b"", b"secret remote failure")
            return commands(arguments, **kwargs)
        result = worker.execute({"root": str(self.root)}, runner=failed_remote)
        self.assertTrue(result["ok"], result)
        self.assertEqual([row["id"] for row in result["repos"]], ["owner/b"])
        self.assertIn("could not read", " ".join(result["warnings"]))
        self.assertNotIn("secret", json.dumps(result))

    def test_more_pages_without_valid_cursor_is_error_not_truncated_success(self):
        self.repository("repo", {"origin": "git@github.com:owner/repo"})
        for cursor in ("", "bad cursor", None):
            response = connection([pull(1)], total=50, cursor="placeholder")
            response["data"]["repository"]["pullRequests"]["pageInfo"]["endCursor"] = cursor
            with self.subTest(cursor=cursor):
                result, commands = self.execute({endpoint("owner/repo"): response})
                self.assertTrue(result["ok"])
                self.assertIn("invalid pull request page", result["repos"][0]["error"])
                self.assertEqual(result["repos"][0]["prs"], [])

    def test_failed_repository_retains_other_repos(self):
        self.repository("a", {"origin": "git@github.com:owner/a"})
        self.repository("b", {"origin": "git@github.com:owner/b"})
        failure = subprocess.CompletedProcess([], 1, b"", b"HTTP 503 secret-credential https://secret@example.com")
        result, commands = self.execute({endpoint("owner/a"): failure, endpoint("owner/b"): [pull(1, identity="owner/b")]})
        self.assertTrue(result["ok"], result)
        self.assertIn("error", result["repos"][0])
        self.assertEqual(result["repos"][0]["prs"], [])
        self.assertEqual(len(result["repos"][1]["prs"]), 1)
        self.assertNotIn("secret", json.dumps(result))

    def test_repo_timeout_preserves_other_results_and_bounds_commands(self):
        self.repository("a", {"origin": "git@github.com:owner/a"})
        self.repository("b", {"origin": "git@github.com:owner/b"})
        result, commands = self.execute({endpoint("owner/a"): subprocess.TimeoutExpired(["gh"], 20), endpoint("owner/b"): []})
        self.assertTrue(result["ok"], result)
        self.assertIn("timed out", result["repos"][0]["error"])
        self.assertNotIn("error", result["repos"][1])
        for args, kwargs in commands.calls:
            self.assertGreater(kwargs["timeout"], 0)
            self.assertLessEqual(kwargs["timeout"], worker.COMMAND_SECONDS)
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertNotIn("shell", kwargs)

    def test_overall_budget_stops_requests_and_marks_unloaded_repos(self):
        self.repository("a", {"origin": "git@github.com:owner/a"})
        self.repository("b", {"origin": "git@github.com:owner/b"})
        original = worker.Client.pulls
        def expire(client, identity, after=None):
            client.until = -1
            return original(client, identity, after)
        with mock.patch.object(worker.Client, "pulls", expire):
            result, commands = self.execute()
        self.assertTrue(result["ok"], result)
        self.assertTrue(all("timed out" in row["error"] for row in result["repos"]))
        self.assertEqual(commands.api_calls(), ["user"])

    def test_login_missing_cli_and_offline_are_actionable_without_raw_stderr(self):
        for stderr, setup in ((b"To get started, run gh auth login secret", True), (b"HTTP 401 Bad credentials secret", True), (b"network is unreachable secret", False)):
            with self.subTest(stderr=stderr):
                result, commands = self.execute({"user": subprocess.CompletedProcess([], 1, b"", stderr)})
                self.assertFalse(result["ok"])
                self.assertEqual(result.get("setup", False), setup)
                self.assertNotIn("secret", result["error"])
                self.assertIn("host", result["error"])
        with mock.patch.object(worker, "resolve_gh", return_value=None):
            result, commands = self.execute()
        self.assertFalse(result["ok"])
        self.assertTrue(result["setup"])
        self.assertIn("Install gh", result["error"])
        self.assertEqual(commands.calls, [])

    def test_invalid_api_data_and_unsafe_pr_url_are_repo_errors(self):
        self.repository("repo", {"origin": "git@github.com:owner/repo"})
        for response in ({"message": "not a list"}, [pull(1, url="https://evil.test/secret")], subprocess.CompletedProcess([], 0, b"not JSON secret", b"")):
            with self.subTest(response=response):
                result, commands = self.execute({endpoint("owner/repo"): response})
                self.assertTrue(result["ok"])
                self.assertIn("error", result["repos"][0])
                self.assertEqual(result["repos"][0]["prs"], [])
                self.assertNotIn("secret", json.dumps(result))

    def test_root_errors_canonicalization_and_scanner_warnings(self):
        for root in ("", str(self.root / "missing"), "bad\0root"):
            result = worker.execute({"root": root}, runner=FakeCommands())
            self.assertFalse(result["ok"], result)
            self.assertIn("error", result)
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        result, commands = self.execute(root=alias)
        self.assertEqual(result["root"], str(self.root))
        main = self.repository("main", {"origin": "git@github.com:owner/repo"})
        stale = self.base / "stale"
        self.git(main, "worktree", "add", "-b", "stale", str(stale))
        shutil.rmtree(stale)
        result, commands = self.execute({endpoint("owner/repo"): []})
        self.assertTrue(result["ok"], result)
        self.assertIn("Stale worktree", " ".join(result["warnings"]))

    def test_host_override_cannot_redirect_api_and_git_overrides_are_removed(self):
        self.repository("repo", {"origin": "git@github.com:owner/repo"})
        with mock.patch.dict(os.environ, {"GH_HOST": "evil.test", "GIT_DIR": "/missing", "GH_TOKEN": "fixture-secret"}):
            result, commands = self.execute({endpoint("owner/repo"): []})
        self.assertTrue(result["ok"], result)
        for args, kwargs in commands.calls:
            if args[0] == "/fixture/gh":
                self.assertEqual(kwargs["env"]["GH_HOST"], "github.com")
                self.assertEqual(kwargs["env"]["GH_TOKEN"], "fixture-secret")
            else:
                self.assertNotIn("GIT_DIR", kwargs["env"])
                self.assertEqual(kwargs["env"]["GIT_OPTIONAL_LOCKS"], "0")
        self.assertNotIn("fixture-secret", json.dumps(result))


class StdioTests(unittest.TestCase):
    def test_invalid_requests_emit_only_one_json_object(self):
        for request in (b"not json", b"null", b'{}', b"x" * (worker.MAX_REQUEST + 1)):
            with self.subTest(length=len(request)):
                result = subprocess.run([sys.executable, str(WORKER_PATH)], input=request, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=True)
                parsed = json.loads(result.stdout)
                self.assertFalse(parsed["ok"])
                self.assertEqual(parsed["repos"], [])
                self.assertEqual(result.stderr, b"")
                self.assertEqual(len(result.stdout.splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
