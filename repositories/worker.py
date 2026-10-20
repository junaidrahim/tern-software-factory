#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Read-only host repository discovery; input and output are JSON over stdio."""
from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


SCAN_SECONDS = 110
GIT_SECONDS = 10
MAX_REQUEST = 64 * 1024
PRUNED = {".git", ".cache", "node_modules", ".venv", "venv", "target", "dist", "build", "__pycache__"}
GIT_METADATA = {"objects", "refs", "reftable", "logs", "hooks", "info", "branches", "worktrees"}


class DiscoveryError(Exception):
    pass


class ScanTimeout(DiscoveryError):
    pass


@contextmanager
def deadline(seconds):
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_delay, previous_interval = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()

    def expired(signum, frame):
        raise ScanTimeout("Repository scan timed out. Choose a smaller root folder and refresh.")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, min(seconds, previous_delay) if previous_delay else seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_delay:
            signal.setitimer(signal.ITIMER_REAL, max(0.001, previous_delay - (time.monotonic() - started)), previous_interval)


def canonical(path):
    return str(Path(path).resolve())


def alphabetical(value):
    return value.casefold(), value


class Scanner:
    def __init__(self, git, seconds):
        self.git = git
        self.until = time.monotonic() + seconds
        self.warnings = []
        self.repos = {}
        # Git's inherited repository/config overrides must not redirect discovery.
        self.environ = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.environ.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")

    def remaining(self):
        remaining = self.until - time.monotonic()
        if remaining <= 0:
            raise ScanTimeout("Repository scan timed out. Choose a smaller root folder and refresh.")
        return remaining

    def command(self, directory, *arguments):
        timeout = min(GIT_SECONDS, self.remaining())
        try:
            result = subprocess.run(
                [self.git, "-C", directory, *arguments],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=self.environ, timeout=timeout, check=False,
            )
        except subprocess.TimeoutExpired as exc:
            self.remaining()
            raise DiscoveryError(f"Git timed out while reading {directory}.") from exc
        except OSError as exc:
            raise DiscoveryError(f"Cannot run Git for {directory}: {exc}") from exc
        if result.returncode:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            raise DiscoveryError(f"Cannot read repository {directory}: {detail or 'Git exited with status ' + str(result.returncode)}")
        return result.stdout

    def repository(self, directory):
        common_output = self.command(directory, "rev-parse", "--path-format=absolute", "--git-common-dir")
        common = canonical(os.fsdecode(common_output.removesuffix(b"\n")))
        main_checkout = None
        marker = os.path.join(directory, ".git")
        if os.path.isdir(marker):
            if canonical(marker) == common:
                main_checkout = directory
        elif os.path.isfile(marker):
            git_dir = self.command(directory, "rev-parse", "--absolute-git-dir")
            if canonical(os.fsdecode(git_dir.removesuffix(b"\n"))) == common:
                main_checkout = directory
        if common in self.repos:
            if main_checkout:
                self.repos[common]["path"] = main_checkout
                self.repos[common]["name"] = os.path.basename(main_checkout) or main_checkout
            return common
        output = self.command(directory, "worktree", "list", "--porcelain", "-z")
        records = []
        for record in output.split(b"\0\0"):
            if not record:
                continue
            fields = record.split(b"\0")
            if not fields[0].startswith(b"worktree "):
                raise DiscoveryError(f"Git returned an invalid worktree list for {directory}.")
            path = canonical(os.fsdecode(fields[0][len(b"worktree "):]))
            values = {}
            for field in fields[1:]:
                key, _, value = field.partition(b" ")
                values[key] = value
            branch = os.fsdecode(values.get(b"branch", b"")).removeprefix("refs/heads/")
            records.append({
                "path": path,
                "branch": branch,
                "detached": b"detached" in values,
                "locked": b"locked" in values,
                "missing": not os.path.isdir(path),
            })
            if b"prunable" in values:
                reason = os.fsdecode(values[b"prunable"])
                self.warnings.append(f"Stale worktree {path}: {reason or 'Git marks this registration prunable'}.")
        if not records:
            raise DiscoveryError(f"Git returned no main worktree for {directory}.")
        # Git guarantees the main checkout (or bare repository) is first, even
        # when the command runs inside a linked worktree outside the scan root.
        # A separate --git-dir has no backlink to its main checkout. Prefer the
        # checkout encountered on disk over the metadata path Git lists for it.
        main = main_checkout or records[0]["path"]
        children = {record["path"]: record for record in records[1:] if record["path"] != main}
        self.repos[common] = {
            "path": main,
            "name": os.path.basename(main) or main,
            "worktrees": sorted(children.values(), key=lambda row: alphabetical(row["path"])),
        }
        return common

    def scan(self, root):
        pending = [root]
        while pending:
            self.remaining()
            directory = pending.pop()
            try:
                with os.scandir(directory) as entries:
                    names = set()
                    children = []
                    for entry in entries:
                        self.remaining()
                        names.add(entry.name)
                        if entry.name not in PRUNED and entry.is_dir(follow_symlinks=False):
                            children.append(entry.path)
            except OSError as exc:
                self.warnings.append(f"Cannot scan folder {directory}: {exc}")
                continue
            metadata_hint = {"HEAD", "objects"}.issubset(names)
            metadata = False
            if ".git" in names or metadata_hint:
                try:
                    metadata = self.repository(directory) == canonical(directory)
                except ScanTimeout:
                    raise
                except (DiscoveryError, OSError, ValueError, RuntimeError) as exc:
                    self.warnings.append(str(exc))
            if metadata:
                children = [child for child in children if os.path.basename(child) not in GIT_METADATA]
            pending.extend(sorted(children, key=alphabetical, reverse=True))
        return sorted(self.repos.values(), key=lambda repo: (alphabetical(repo["name"]), alphabetical(repo["path"])))


def execute(request, *, seconds=SCAN_SECONDS):
    root = ""
    scanner = None
    try:
        with deadline(max(0.001, seconds)):
            if not isinstance(request, dict) or not isinstance(request.get("root"), str) or not request["root"]:
                raise DiscoveryError("Choose a repository root folder before scanning.")
            if "\0" in request["root"]:
                raise DiscoveryError("Repository root cannot contain a NUL character.")
            root = canonical(os.path.expanduser(request["root"]))
            if not os.path.exists(root):
                raise DiscoveryError(f"Repository root does not exist: {root}")
            if not os.path.isdir(root):
                raise DiscoveryError(f"Repository root is not a folder: {root}")
            git = shutil.which("git")
            if not git:
                raise DiscoveryError("Git is not installed or is not available on the host PATH.")
            scanner = Scanner(git, seconds)
            repos = scanner.scan(root)
            if not repos and scanner.warnings:
                raise DiscoveryError("Repository scan could not read repositories. " + scanner.warnings[0])
            result = {"ok": True, "root": root, "repos": repos}
            if scanner.warnings:
                result["warnings"] = sorted(set(scanner.warnings), key=alphabetical)
            return result
    except (DiscoveryError, OSError, ValueError, RuntimeError) as exc:
        result = {"ok": False, "root": root, "repos": [], "error": str(exc)}
        if scanner and scanner.warnings:
            result["warnings"] = sorted(set(scanner.warnings), key=alphabetical)
        return result


def main():
    try:
        data = sys.stdin.buffer.read(MAX_REQUEST + 1)
        if len(data) > MAX_REQUEST:
            raise DiscoveryError("Repository request exceeds the size limit.")
        request = json.loads(data)
        result = execute(request)
    except (DiscoveryError, ValueError, UnicodeError) as exc:
        result = {"ok": False, "root": "", "repos": [], "error": f"Invalid repository request: {exc}"}
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
