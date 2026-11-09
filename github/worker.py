#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Read-only GitHub PR discovery for the shared repository root; JSON stdio."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from urllib.parse import urlsplit


SPEC = importlib.util.spec_from_file_location(
    "factory_repository_discovery", Path(__file__).resolve().parents[1] / "repositories" / "worker.py"
)
discovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(discovery)

TOTAL_SECONDS = 110
COMMAND_SECONDS = 20
MAX_REQUEST = 64 * 1024
# Open PRs per repository per request; the block asks for more pages on demand.
PAGE_SIZE = 10
PARALLEL_REPOSITORIES = 8
MAX_CURSOR = 512
CURSOR = re.compile(r"[A-Za-z0-9+/=_-]+\Z")
# Select only rendered fields: REST PR objects are ~20 KB each and repositories can have thousands.
PULLS_QUERY = (
    "query($owner:String!,$name:String!,$first:Int!,$after:String){repository(owner:$owner,name:$name){"
    "pullRequests(states:OPEN,first:$first,after:$after,orderBy:{field:UPDATED_AT,direction:DESC}){"
    "totalCount pageInfo{hasNextPage endCursor} "
    "nodes{number title url isDraft headRefName baseRefName updatedAt author{login}}}}}"
)
OWNER = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+\Z")


class GitHubError(Exception):
    def __init__(self, message, *, setup=False):
        super().__init__(message)
        self.setup = setup


class DeadlineExceeded(GitHubError):
    pass


def remote_repository(value):
    """Return a safe owner/repo, never credentials, for GitHub.com clone URLs."""
    if not isinstance(value, str) or not value or any(ord(char) <= 32 or ord(char) == 127 for char in value):
        return None
    if value.startswith("git@") and "://" not in value:
        match = re.fullmatch(r"git@github\.com:([^?#]+)", value, re.IGNORECASE)
        if not match:
            return None
        path = match[1]
    else:
        try:
            parsed = urlsplit(value)
            if parsed.scheme not in {"https", "ssh"} or parsed.hostname != "github.com":
                return None
            if parsed.query or parsed.fragment or "?" in value or "#" in value:
                return None
            if parsed.scheme == "https" and parsed.port not in {None, 443}:
                return None
            if parsed.scheme == "ssh" and (parsed.username != "git" or parsed.password is not None or parsed.port not in {None, 22}):
                return None
            path = parsed.path.removeprefix("/")
        except ValueError:
            return None
    path = path.removesuffix("/").removesuffix(".git")
    pieces = path.split("/")
    if len(pieces) != 2 or not OWNER.fullmatch(pieces[0]) or not REPOSITORY.fullmatch(pieces[1]) or pieces[1] in {".", ".."}:
        return None
    return "/".join(pieces)


def resolve_gh():
    found = shutil.which("gh")
    if found:
        return found
    for path in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh"):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


class Client:
    def __init__(self, gh, git, seconds, runner=subprocess.run):
        self.gh = gh
        self.git = git
        self.until = time.monotonic() + seconds
        self.runner = runner
        self.git_env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.git_env.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
        # Preserve the host authentication environment without inspecting credentials.
        self.gh_env = dict(os.environ, GH_PROMPT_DISABLED="1", GH_PAGER="cat", GH_HOST="github.com")

    def remaining(self):
        remaining = self.until - time.monotonic()
        if remaining <= 0:
            raise DeadlineExceeded("GitHub refresh timed out. Choose a smaller root or refresh again.")
        return remaining

    def command(self, arguments, *, git=False, allow_missing=False):
        try:
            result = self.runner(
                arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=self.git_env if git else self.gh_env,
                timeout=min(10 if git else COMMAND_SECONDS, self.remaining()), check=False,
            )
        except subprocess.TimeoutExpired as exc:
            self.remaining()
            raise GitHubError("Git timed out while reading remotes." if git else "GitHub request timed out. Check connectivity and refresh.") from exc
        except OSError as exc:
            raise GitHubError("Cannot run Git on this host." if git else "Cannot run GitHub CLI on this host. Install gh and refresh.", setup=not git) from exc
        if result.returncode and not (allow_missing and result.returncode == 1):
            if git:
                raise GitHubError("Git could not read repository remotes.")
            # Classify only; never expose stderr, which can contain credentials or URLs.
            detail = result.stderr.decode("utf-8", errors="replace").casefold()
            if any(text in detail for text in ("gh auth login", "not logged", "http 401", "bad credentials", "requires authentication")):
                raise GitHubError("GitHub authentication is required. Run gh auth login --hostname github.com on the host, then refresh.", setup=True)
            if "http 403" in detail or "rate limit" in detail:
                raise GitHubError("GitHub denied the request or its rate limit was reached. Check account access and refresh later.")
            if "http 404" in detail or "could not resolve to a repository" in detail:
                raise GitHubError("GitHub repository was not found or your host account lacks access.")
            raise GitHubError("GitHub request failed. Check host connectivity and gh auth status --hostname github.com, then refresh.")
        return result.stdout if result.returncode == 0 else b""

    def repository(self, path, warnings):
        data = self.command([self.git, "-C", path, "config", "--null", "--get-regexp", r"^remote\..*\.url$"], git=True, allow_missing=True)
        candidates = []
        for record in data.split(b"\0"):
            if not record:
                continue
            key, separator, raw_url = record.partition(b"\n")
            if not separator or not key.startswith(b"remote.") or not key.endswith(b".url"):
                raise GitHubError("Git returned an invalid remote configuration.")
            remote = os.fsdecode(key[len(b"remote."):-len(b".url")])
            url = raw_url.decode("utf-8", errors="replace")
            identity = remote_repository(url)
            if identity:
                priority = 0 if remote == "origin" else 1 if remote == "upstream" else 2
                candidates.append(((priority, remote.casefold(), remote), identity))
            elif "github.com" in url.casefold():
                warnings.append(f"Ignored an unsupported or malformed GitHub remote in {path}.")
        return min(candidates, key=lambda item: item[0])[1] if candidates else None

    def api(self, arguments):
        data = self.command([self.gh, "api", *arguments])
        try:
            return json.loads(data)
        except (ValueError, UnicodeError) as exc:
            raise GitHubError("GitHub returned an invalid JSON response. Refresh again.") from exc

    def authenticate(self):
        user = self.api(["--hostname", "github.com", "user"])
        if not isinstance(user, dict) or not isinstance(user.get("login"), str) or not user["login"]:
            raise GitHubError("GitHub returned an invalid account response. Check gh auth status --hostname github.com.")

    def pulls(self, identity, after=None):
        """Return one page of open PRs, newest update first, with the total and next cursor."""
        self.remaining()
        owner, name = identity.split("/")
        arguments = ["graphql", "--hostname", "github.com", "-f", f"query={PULLS_QUERY}",
                     "-f", f"owner={owner}", "-f", f"name={name}", "-F", f"first={PAGE_SIZE}"]
        if after:
            arguments += ["-f", f"after={after}"]
        data = self.api(arguments)
        try:
            connection = data["data"]["repository"]["pullRequests"]
            total, info, nodes = connection["totalCount"], connection["pageInfo"], connection["nodes"]
            more, cursor = info["hasNextPage"], info["endCursor"]
            if type(total) is not int or total < 0 or type(more) is not bool or not isinstance(nodes, list):
                raise ValueError()
            if more and not valid_cursor(cursor):
                raise ValueError()
        except (KeyError, TypeError, ValueError) as exc:
            raise GitHubError("GitHub returned an invalid pull request page.") from exc
        rows, seen = [], set()
        for item in nodes:
            row = pull_request(item, identity)
            if row["number"] not in seen:
                seen.add(row["number"])
                rows.append(row)
        page = {"prs": rows, "total": total}
        if more:
            page["cursor"] = cursor
        return page


def valid_cursor(value):
    return isinstance(value, str) and 0 < len(value) <= MAX_CURSOR and CURSOR.fullmatch(value) is not None


def valid_identity(value):
    return isinstance(value, str) and remote_repository(f"https://github.com/{value}") == value


def pull_request(item, identity):
    try:
        number = item["number"]
        if type(number) is not int or number <= 0:
            raise ValueError()
        url = item["url"]
        parsed = urlsplit(url)
        if (parsed.scheme != "https" or parsed.netloc.casefold() != "github.com"
                or parsed.path.casefold() != f"/{identity}/pull/{number}".casefold()
                or parsed.query or parsed.fragment or "?" in url or "#" in url
                or any(ord(char) <= 32 or ord(char) == 127 for char in url)):
            raise ValueError()
        title, head, base, updated_at = item["title"], item["headRefName"], item["baseRefName"], item["updatedAt"]
        author = item["author"]["login"] if item.get("author") is not None else ""
        draft = item.get("isDraft", False)
        if not all(isinstance(value, str) for value in (title, head, base, updated_at, author)) or type(draft) is not bool:
            raise ValueError()
        if datetime.fromisoformat(updated_at.replace("Z", "+00:00")).tzinfo is None:
            raise ValueError()
        return {
            "number": number, "title": title, "url": url, "author": author, "draft": draft,
            "head": head, "base": base, "updated_at": updated_at,
        }
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError) as exc:
        raise GitHubError("GitHub returned invalid pull request data or an unsafe URL; this repository was not refreshed.") from exc


def execute(request, *, seconds=TOTAL_SECONDS, runner=subprocess.run):
    # Every Git and gh call is bounded by the Client budget, so a budget overrun ends the PR phase with
    # per-repository timeouts instead of discarding every loaded page; no SIGALRM can preempt the pool.
    seconds = min(TOTAL_SECONDS, max(0.001, seconds))
    if isinstance(request, dict) and "repo" in request:
        return execute_page(request, seconds, runner)
    root = ""
    repos = []
    warnings = []
    started = time.monotonic()
    try:
        scanned = discovery.execute(request, seconds=seconds)
        root = scanned["root"]
        warnings.extend(scanned.get("warnings", []))
        if not scanned["ok"]:
            raise GitHubError(scanned["error"])
        gh = resolve_gh()
        if not gh:
            raise GitHubError("GitHub CLI is not installed on the host. Install gh, run gh auth login --hostname github.com, then refresh.", setup=True)
        client = Client(gh, shutil.which("git"), seconds - (time.monotonic() - started), runner)

        def remote(local):
            found = []
            try:
                return client.repository(local["path"], found), found
            except DeadlineExceeded:
                raise
            except GitHubError as exc:
                return None, [*found, f"{local['path']}: {exc}"]

        def first_page(repo):
            try:
                repo.update(client.pulls(repo["id"]))
            except GitHubError as exc:
                repo["error"] = str(exc)

        # Remote reads, the account check, and PR requests are process/network-bound; one slow
        # repository must not serialize the rest. Workers only touch their own repo dict.
        with ThreadPoolExecutor(max_workers=PARALLEL_REPOSITORIES) as pool:
            account = pool.submit(client.authenticate)
            identities = set()
            for local, (identity, found) in zip(scanned["repos"], pool.map(remote, scanned["repos"])):
                warnings.extend(found)
                if identity and identity.casefold() not in identities:
                    identities.add(identity.casefold())
                    repos.append({"id": identity, "name": identity, "url": f"https://github.com/{identity}", "path": local["path"], "prs": []})
            account.result()
            repos.sort(key=lambda repo: (repo["name"].casefold(), repo["name"]))
            list(pool.map(first_page, repos))
        result = {"ok": True, "root": root, "repos": repos}
    except (GitHubError, OSError, ValueError, RuntimeError) as exc:
        result = {"ok": False, "root": root, "repos": repos, "error": str(exc)}
        if isinstance(exc, GitHubError) and exc.setup:
            result["setup"] = True
    if warnings:
        result["warnings"] = sorted(set(warnings), key=lambda value: (value.casefold(), value))
    return result


def execute_page(request, seconds, runner):
    """Load the page after `after` for one known repository, skipping discovery."""
    identity, after = request.get("repo"), request.get("after")
    if not valid_identity(identity) or not valid_cursor(after):
        return {"ok": False, "error": "Invalid GitHub page request: expected a repository and cursor."}
    try:
        gh = resolve_gh()
        if not gh:
            raise GitHubError("GitHub CLI is not installed on the host. Install gh, run gh auth login --hostname github.com, then refresh.", setup=True)
        return {"ok": True, "repo": identity, **Client(gh, None, seconds, runner).pulls(identity, after)}
    except GitHubError as exc:
        result = {"ok": False, "repo": identity, "error": str(exc)}
        if exc.setup:
            result["setup"] = True
        return result


def main():
    try:
        data = sys.stdin.buffer.read(MAX_REQUEST + 1)
        if len(data) > MAX_REQUEST:
            raise ValueError("request exceeds the size limit")
        request = json.loads(data)
        result = execute(request)
    except (ValueError, UnicodeError) as exc:
        result = {"ok": False, "root": "", "repos": [], "error": "Invalid GitHub request: expected a JSON object with a repository root."}
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    main()
