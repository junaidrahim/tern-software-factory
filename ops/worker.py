#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Read only rolling model estimates, recorded commands, and retained usage."""
from __future__ import annotations

import json
import math
from pathlib import Path
import sqlite3
import sys
import time
import unicodedata

try:
    from ops.history import read_history
except ModuleNotFoundError as exc:
    if exc.name != "ops":
        raise
    from history import read_history


MAX_REQUEST = 4096
MAX_NAME = 160
MODEL_SQL = "SELECT model_key, samples, output_tokens, gen_ms, ttft_samples, ttft_ms, updated_at FROM model_perf"
COMMAND_SQL = "SELECT name, count, last_used_at FROM command_usage"


def display_name(value):
    if not isinstance(value, str):
        return "(unnamed)"
    # Strip terminal controls, bidi overrides, and line separators from native labels.
    value = "".join(char for char in value if not unicodedata.category(char).startswith("C") and char not in "\u2028\u2029")
    return value[:MAX_NAME].strip() or "(unnamed)"


def number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    return value if math.isfinite(value) and value >= 0 else None


def ratio(numerator, denominator, scale=1):
    numerator, denominator = number(numerator), number(denominator)
    if numerator is None or denominator is None or denominator <= 0:
        return None
    # Divide first to avoid overflow for otherwise representable rates.
    return number((numerator / denominator) * scale)


def total(values):
    values = list(values)
    if any(value is None for value in values):
        return None
    try:
        return number(math.fsum(values))
    except OverflowError:
        return None


def table_rows(connection, query, label, warnings):
    try:
        return connection.execute(query).fetchall()
    except sqlite3.OperationalError as exc:
        # Only absent/incompatible schema permits a partial snapshot. Busy, I/O,
        # and malformed-database failures must not masquerade as empty data.
        if getattr(exc, "sqlite_errorcode", None) != sqlite3.SQLITE_ERROR:
            raise
        warnings.append(f"{label} unavailable: expected table or columns are missing or incompatible.")
        return None


def read_stats(path, now=None):
    connection = None
    try:
        path = Path(path).expanduser().absolute()
        if not path.exists():
            return {"ok": False, "error": "Agent database not found. Run omp on this host to record activity.", "setup": True}
        connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.25)
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA trusted_schema = OFF")
        # The first SELECT establishes one SQLite snapshot for both tables.
        connection.execute("BEGIN")
        warnings = []
        model_rows = table_rows(connection, MODEL_SQL, "Model performance", warnings)
        command_rows = table_rows(connection, COMMAND_SQL, "Recorded commands", warnings)
        if model_rows is None and command_rows is None:
            return {"ok": False, "error": "Agent database has no compatible model performance or command usage tables."}

        models = []
        for key, samples, tokens, gen_ms, ttft_samples, ttft_ms, updated_at in model_rows or []:
            models.append({
                "model_key": display_name(key),
                "tokens_per_second": ratio(tokens, gen_ms, 1000),
                "ttft_ms": ratio(ttft_ms, ttft_samples),
                "avg_output_tokens": ratio(tokens, samples),
                "effective_samples": number(samples),
                "updated_at": number(updated_at),
            })
        models.sort(key=lambda row: (-(row["updated_at"] if row["updated_at"] is not None else -1), row["model_key"]))
        samples_total = total(row["effective_samples"] for row in models) if model_rows is not None else None
        if model_rows is not None and samples_total is None:
            warnings.append("Some effective sample measurements are missing or invalid; their total is unavailable.")

        commands = []
        invalid_counts = False
        for name, count, last_used_at in command_rows or []:
            if not isinstance(count, int) or count < 0:
                invalid_counts = True
                continue
            commands.append({"name": display_name(name), "count": count, "last_used_at": number(last_used_at)})
        commands.sort(key=lambda row: (-row["count"], row["name"]))
        if invalid_counts:
            warnings.append("Some recorded command counts are invalid; those entries and the command total are unavailable.")
        command_total = sum(row["count"] for row in commands) if command_rows is not None and not invalid_counts else None
        generated_at = number(time.time() if now is None else now)
        if generated_at is None:
            return {"ok": False, "error": "Cannot generate agent snapshot with an invalid timestamp."}
        return {"ok": True, "snapshot": {
            "generated_at": generated_at,
            "models": models,
            "commands": commands[:5],
            "summary": {
                "measured_models": sum(any(row[field] is not None for field in ("tokens_per_second", "ttft_ms", "avg_output_tokens")) for row in models) if model_rows is not None else None,
                "effective_samples": samples_total,
                "command_uses": command_total,
            },
            "warnings": warnings,
        }}
    except (sqlite3.Error, OSError, ValueError, OverflowError):
        # Never echo host paths, database contents, or driver error strings.
        return {"ok": False, "error": "Cannot read agent database. It may be locked, unreadable, or malformed; refresh to retry."}
    finally:
        if connection is not None:
            connection.close()


def execute(request):
    if not isinstance(request, dict) or request.get("action") != "snapshot":
        return {"ok": False, "error": "Expected an agent snapshot request."}
    path = Path.home() / ".omp" / "agent" / "agent.db"
    result = read_stats(path)
    activity = read_history(path.parent / "sessions")
    if result["ok"]:
        result["snapshot"]["activity"] = activity
        return result
    if activity["available"]:
        return {"ok": True, "snapshot": {
            "generated_at": time.time(),
            "models": [],
            "commands": [],
            "summary": {"measured_models": None, "effective_samples": None, "command_uses": None},
            "warnings": [result["error"]],
            "activity": activity,
        }}
    result["activity"] = activity
    result["error"] += " Retained session history is also unavailable; check this host's omp sessions directory."
    return result


def main():
    try:
        data = sys.stdin.buffer.read(MAX_REQUEST + 1)
        if len(data) > MAX_REQUEST:
            result = {"ok": False, "error": "Agent request exceeds the size limit."}
        else:
            result = execute(json.loads(data))
    except (ValueError, UnicodeError):
        result = {"ok": False, "error": "Invalid agent request JSON."}
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))


if __name__ == "__main__":
    main()
