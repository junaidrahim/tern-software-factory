"""Repository discovery tests using temporary real Git repositories and worktrees.

Run: python3 -m unittest discover -s tests -p test_repositories_worker.py
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


WORKER_PATH = Path(__file__).resolve().parents[1] / "repositories" / "worker.py"
SPEC = importlib.util.spec_from_file_location("repositories_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = worker
SPEC.loader.exec_module(worker)


@unittest.skipUnless(shutil.which("git"), "Git is required for repository integration tests")
class RepositoryWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "root"
        self.root.mkdir()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "Repository Test",
            "GIT_AUTHOR_EMAIL": "repository@example.invalid",
            "GIT_COMMITTER_NAME": "Repository Test",
            "GIT_COMMITTER_EMAIL": "repository@example.invalid",
            "GIT_TERMINAL_PROMPT": "0",
        })

    def git(self, directory, *arguments):
        return subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull,
             "-C", str(directory), *arguments],
            env=self.env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8", timeout=15,
        ).stdout

    def repository(self, path, *, commit=True, bare=False):
        path.mkdir(parents=True)
        self.git(path, "init", "--initial-branch=main", *(["--bare"] if bare else []))
        if commit and not bare:
            self.git(path, "commit", "--allow-empty", "-m", "Initial test commit")
        return path

    def worktree(self, repo, path, branch="topic", *, detached=False):
        if detached:
            self.git(repo, "worktree", "add", "--detach", str(path), "HEAD")
        else:
            self.git(repo, "worktree", "add", "-b", branch, str(path))
        return path

    def scan(self, root=None):
        result = worker.execute({"root": str(self.root if root is None else root)})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["root"], str((self.root if root is None else root).resolve()))
        return result

    def test_root_itself_and_unborn_repository(self):
        repo = self.repository(self.root / "unborn", commit=False)
        self.assertEqual(self.scan(repo)["repos"], [{"path": str(repo), "name": "unborn", "worktrees": []}])

    def test_nested_repositories_are_not_hidden_by_parent(self):
        repo = self.repository(self.root / "outer")
        nested = self.repository(repo / "src" / "inner")
        self.assertEqual([row["path"] for row in self.scan()["repos"]], [str(nested), str(repo)])

    def test_linked_checkout_encountered_before_main_is_deduplicated(self):
        main = self.repository(self.root / "z-main")
        linked = self.worktree(main, self.root / "a-linked")
        rows = self.scan()["repos"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["path"], str(main))
        self.assertEqual(rows[0]["worktrees"], [{
            "path": str(linked), "branch": "topic", "detached": False, "locked": False, "missing": False,
        }])

    def test_linked_worktree_only_root_finds_main_and_outside_sibling(self):
        main = self.repository(self.base / "main")
        linked = self.worktree(main, self.root / "linked", "inside")
        outside = self.worktree(main, self.base / "outside", "outside")
        rows = self.scan(linked)["repos"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["path"], str(main))
        self.assertEqual({row["path"] for row in rows[0]["worktrees"]}, {str(linked), str(outside)})
        self.assertNotIn(str(main), [row["path"] for row in rows[0]["worktrees"]])

    def test_unicode_spaces_percent_hash_newlines_and_branch_labels(self):
        main = self.repository(self.root / "main 雪 % #\nrepo")
        child = self.worktree(main, self.base / "linked 雪 % #\ncheckout", "feature/雪-%23")
        row = self.scan()["repos"][0]
        self.assertEqual(row["name"], main.name)
        self.assertEqual(row["path"], str(main))
        self.assertEqual(row["worktrees"][0]["path"], str(child))
        self.assertEqual(row["worktrees"][0]["branch"], "feature/雪-%23")

    def test_detached_and_locked_worktrees(self):
        main = self.repository(self.root / "main")
        detached = self.worktree(main, self.base / "detached", detached=True)
        locked = self.worktree(main, self.base / "locked", "locked-branch")
        self.git(main, "worktree", "lock", "--reason", "Keep this checkout", str(locked))
        children = {row["path"]: row for row in self.scan()["repos"][0]["worktrees"]}
        self.assertEqual(children[str(detached)]["branch"], "")
        self.assertTrue(children[str(detached)]["detached"])
        self.assertFalse(children[str(detached)]["locked"])
        self.assertTrue(children[str(locked)]["locked"])
        self.assertFalse(children[str(locked)]["detached"])

    def test_stale_missing_worktree_is_reported_without_pruning(self):
        main = self.repository(self.root / "main")
        stale = self.worktree(main, self.base / "stale")
        shutil.rmtree(stale)
        before = self.git(main, "worktree", "list", "--porcelain", "-z")
        result = self.scan()
        child = result["repos"][0]["worktrees"][0]
        self.assertEqual(child["path"], str(stale))
        self.assertTrue(child["missing"])
        self.assertEqual(child["branch"], "topic")
        self.assertIn("warnings", result)
        self.assertIn(str(stale), "\n".join(result["warnings"]))
        self.assertEqual(self.git(main, "worktree", "list", "--porcelain", "-z"), before)

    def test_bare_repository_parent_and_linked_worktree(self):
        bare = self.repository(self.root / "storage.git", bare=True)
        seed = self.repository(self.base / "seed")
        self.git(seed, "push", str(bare), "main")
        child = self.worktree(bare, self.base / "bare-checkout", "checkout")
        row = self.scan()["repos"][0]
        self.assertEqual(row["path"], str(bare))
        self.assertEqual(row["name"], "storage.git")
        self.assertEqual([item["path"] for item in row["worktrees"]], [str(child)])

    def test_separate_git_directory_is_canonically_deduplicated(self):
        main = self.root / "a-main"
        main.mkdir()
        metadata = self.root / "z-metadata"
        self.git(main, "init", "--initial-branch=main", "--separate-git-dir=" + str(metadata))
        self.git(main, "commit", "--allow-empty", "-m", "Initial test commit")
        rows = self.scan()["repos"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["path"], str(main))

    def test_directory_symlinks_are_not_followed_but_explicit_root_is_canonical(self):
        outside = self.repository(self.base / "outside")
        alias = self.root / "alias"
        alias.symlink_to(outside, target_is_directory=True)
        (self.root / "loop").symlink_to(self.root, target_is_directory=True)
        self.assertEqual(self.scan()["repos"], [])
        self.assertEqual(self.scan(alias)["repos"][0]["path"], str(outside))

    def test_generated_folders_and_git_metadata_are_pruned(self):
        main = self.repository(self.root / "main")
        for name in [".cache", "node_modules", ".venv", "venv", "target", "dist", "build", "__pycache__"]:
            self.repository(self.root / name / "hidden")
        self.repository(main / ".git" / "hidden")
        visible = self.repository(self.root / ".custom" / "visible")
        self.assertEqual([row["path"] for row in self.scan()["repos"]], [str(main), str(visible)])

    def test_deep_nested_repository_has_no_arbitrary_depth_limit(self):
        deep = self.repository(self.root.joinpath(*(["nested"] * 80), "deep"))
        self.assertEqual([row["path"] for row in self.scan()["repos"]], [str(deep)])

    def test_order_is_deterministic_by_name_then_path(self):
        paths = [self.repository(self.root / name) for name in ["zeta", "Beta", "alpha"]]
        main = paths[0]
        late = self.worktree(main, self.base / "z-child", "late")
        early = self.worktree(main, self.base / "a-child", "early")
        rows = self.scan()["repos"]
        self.assertEqual([row["name"] for row in rows], ["alpha", "Beta", "zeta"])
        self.assertEqual([row["path"] for row in rows[-1]["worktrees"]], [str(early), str(late)])

    def test_invalid_roots_have_useful_errors(self):
        plain_file = self.root / "file"
        plain_file.write_text("not a directory")
        for value, message in [("", "Choose"), (None, "Choose"), (123, "Choose"),
                               ("bad\0path", "NUL"), (str(self.root / "absent"), "does not exist"),
                               (str(plain_file), "not a folder")]:
            with self.subTest(root=value):
                result = worker.execute({"root": value})
                self.assertFalse(result["ok"])
                self.assertEqual(result["repos"], [])
                self.assertIn(message, result["error"])

    def test_corrupt_git_marker_reports_failure_instead_of_empty_success(self):
        invalid = self.root / "broken"
        invalid.mkdir()
        (invalid / ".git").write_text("gitdir: /nonexistent/tern-test-git-directory\n")
        result = worker.execute({"root": str(self.root)})
        self.assertFalse(result["ok"], result)
        self.assertIn(str(invalid), result["error"])

    def test_partial_failure_preserves_valid_repositories_with_warning(self):
        main = self.repository(self.root / "good")
        broken = self.root / "broken"
        broken.mkdir()
        (broken / ".git").write_text("not valid Git metadata\n")
        result = self.scan()
        self.assertEqual([row["path"] for row in result["repos"]], [str(main)])
        self.assertIn(str(broken), "\n".join(result["warnings"]))

    def test_total_deadline_returns_explicit_failure(self):
        result = worker.execute({"root": str(self.root)}, seconds=0)
        self.assertFalse(result["ok"], result)
        self.assertIn("timed out", result["error"])

    def test_stdio_protocol_and_home_expansion(self):
        main = self.repository(self.root / "repo")
        env = dict(self.env, HOME=str(self.base))
        result = subprocess.run(
            [sys.executable, str(WORKER_PATH)], input=json.dumps({"root": "~/root"}),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8", env=env,
            timeout=20, check=True,
        )
        response = json.loads(result.stdout)
        self.assertTrue(response["ok"], response)
        self.assertEqual(response["root"], str(self.root))
        self.assertEqual(response["repos"][0]["path"], str(main))
        self.assertEqual(result.stderr, "")

    def test_invalid_json_stdio_reports_error(self):
        result = subprocess.run(
            [sys.executable, str(WORKER_PATH)], input="not json", stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, encoding="utf-8", env=self.env, timeout=20, check=True,
        )
        response = json.loads(result.stdout)
        self.assertFalse(response["ok"])
        self.assertIn("Invalid repository request", response["error"])
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
