"""Read retained session usage without persisting or exposing transcript contents."""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import stat


TOKEN_FIELDS = ("input", "output", "cache_read", "cache_write", "total")
USAGE_FIELDS = ("input", "output", "cacheRead", "cacheWrite", "totalTokens")


def token_count(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, float) and math.isfinite(value) and value >= 0 and value.is_integer():
        return int(value)
    return None


def response_key(entry, message):
    provider = message.get("provider")
    provider = provider if isinstance(provider, str) else None
    response_id = message.get("responseId")
    if isinstance(response_id, str) and response_id:
        return ("response", provider, response_id)
    entry_id = entry.get("id")
    if not isinstance(entry_id, str) or not entry_id:
        return None
    timestamp = entry.get("timestamp", message.get("timestamp"))
    if not isinstance(timestamp, (str, int, float)) or isinstance(timestamp, bool):
        timestamp = None
    model = message.get("model")
    return ("entry", entry_id, timestamp, provider, model if isinstance(model, str) else None)


def read_history(root):
    """Aggregate unique sessions and metered responses across all retained files.

    Only identifiers and numeric usage survive parsing each line. Descriptor-relative
    traversal and O_NOFOLLOW prevent following session symlinks outside the root.
    Missing measurements remain unavailable, even when other counters are usable.
    """
    warnings = set()
    sessions = set()
    subagents = set()
    responses = {}
    unmetered = set()
    visited = False

    def unavailable():
        return {
            "available": False, "partial": False,
            "sessions": None, "subagents": None, "responses": None,
            "tokens": dict.fromkeys(TOKEN_FIELDS),
            "warnings": ["Retained session history is unavailable. Check that this host has a readable omp sessions directory, then refresh."],
        }

    def unreadable(_error=None):
        warnings.add("Some retained history could not be read; recorded totals are partial.")

    def read_session(stream, nested):
        header = False
        for line in stream:
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except (ValueError, UnicodeError, RecursionError):
                warnings.add("Some retained history is malformed or still being written; recorded totals are partial.")
                continue
            if not isinstance(entry, dict):
                if header:
                    warnings.add("Some retained history is malformed or still being written; recorded totals are partial.")
                    continue
                return
            if not header:
                if entry.get("type") == "title":
                    continue
                session_id = entry.get("id")
                if entry.get("type") != "session":
                    return
                if not isinstance(session_id, str) or not session_id:
                    warnings.add("Some retained history is malformed or still being written; recorded totals are partial.")
                    return
                (subagents if nested else sessions).add(session_id)
                header = True
                continue
            if entry.get("type") != "message":
                continue
            message = entry.get("message")
            if not isinstance(message, dict):
                warnings.add("Some retained history is malformed or still being written; recorded totals are partial.")
                continue
            if message.get("role") != "assistant":
                continue
            key = response_key(entry, message)
            if key is None:
                warnings.add("Some assistant responses lack identifiers needed to count usage uniquely; recorded totals are partial.")
                continue
            usage = message.get("usage")
            values = tuple(token_count(usage.get(field)) for field in USAGE_FIELDS) if isinstance(usage, dict) else (None,) * 5
            if all(value is None for value in values):
                unmetered.add(key)
                continue
            previous = responses.get(key)
            if previous is None:
                responses[key] = values
                continue
            # A copied branch can retain a more complete record of the same response.
            # Conflicting measurements are unavailable rather than selected arbitrarily.
            merged = []
            for old, new in zip(previous, values):
                if old is None:
                    merged.append(new)
                elif new is None or old == new:
                    merged.append(old)
                else:
                    merged.append(-1)
                    warnings.add("Duplicate response records contain conflicting usage; affected token totals are unavailable.")
            responses[key] = tuple(merged)

    try:
        root_fd = os.open(Path(root).expanduser(), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except (OSError, ValueError):
        return unavailable()
    try:
        for directory, dirs, files, directory_fd in os.fwalk(".", dir_fd=root_fd, follow_symlinks=False, onerror=unreadable):
            visited = True
            # Symlinked directories are never traversed, even within the root.
            for name in dirs:
                try:
                    if stat.S_ISLNK(os.stat(name, dir_fd=directory_fd, follow_symlinks=False).st_mode):
                        unreadable()
                except OSError:
                    unreadable()
            nested = len(Path(directory).parts) >= 2
            for name in files:
                if not name.endswith(".jsonl"):
                    continue
                descriptor = None
                try:
                    mode = os.stat(name, dir_fd=directory_fd, follow_symlinks=False).st_mode
                    if not stat.S_ISREG(mode):
                        unreadable()
                        continue
                    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
                    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                        unreadable()
                        continue
                    with os.fdopen(descriptor, "rb") as stream:
                        descriptor = None
                        read_session(stream, nested)
                except OSError:
                    unreadable()
                finally:
                    if descriptor is not None:
                        os.close(descriptor)
    except OSError:
        unreadable()
    finally:
        os.close(root_fd)
    if not visited:
        return unavailable()

    if unmetered.difference(responses):
        warnings.add("Usage is not recorded for all assistant responses; recorded totals are partial.")
    tokens = dict.fromkeys(TOKEN_FIELDS, 0)
    for values in responses.values():
        components = values[:4]
        total = values[4]
        if total is None and all(value is not None and value >= 0 for value in components):
            total = sum(components)
        for field, value in zip(TOKEN_FIELDS, (*components, total)):
            if value is None or value < 0:
                tokens[field] = None
                warnings.add("Some recorded token fields are missing or invalid; affected token totals are unavailable.")
            elif tokens[field] is not None:
                tokens[field] += value
    # A duplicated header is one run, even if found in both layouts. The root
    # placement wins; parentSession alone never makes a root fork a subagent.
    return {
        "available": True, "partial": bool(warnings),
        "sessions": len(sessions), "subagents": len(subagents - sessions),
        "responses": len(responses), "tokens": tokens, "warnings": sorted(warnings),
    }
