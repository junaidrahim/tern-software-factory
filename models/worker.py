#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Artificial Analysis Free API worker. Credentials enter only through JSON stdin."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import date
from email.utils import parsedate_to_datetime
import http.client
import json
import math
import os
from pathlib import Path
import re
import signal
import sys
import tempfile
import time

HOST = "artificialanalysis.ai"
ENDPOINT = "https://artificialanalysis.ai/api/v2/language/models/free?page="
REFRESH_SECONDS = 6 * 3600
FETCH_SECONDS = 15
TOTAL_SECONDS = 90
MAX_REQUEST = 16384
MAX_PAGE_BYTES = 2 * 1024 * 1024
MAX_CACHE_BYTES = 16 * 1024 * 1024
MAX_PAGES = 100
MAX_MODELS = 10000
MAX_KEY_BYTES = 4096
REPO = Path(__file__).resolve().parents[1]
SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.~-]{0,255}\Z")
CONTROLS = re.compile(r"[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]")
METRICS = {
    "intelligence": ("evaluations", "artificial_analysis_intelligence_index"),
    "coding": ("evaluations", "artificial_analysis_coding_index"),
    "agentic": ("evaluations", "artificial_analysis_agentic_index"),
    "input_price": ("pricing", "price_1m_input_tokens"),
    "output_price": ("pricing", "price_1m_output_tokens"),
    "speed": ("performance", "median_output_tokens_per_second"),
    "ttft": ("performance", "median_time_to_first_token_seconds"),
}


class ModelsError(Exception):
    """Messages are fixed local strings, never remote bodies or exception text."""


class SetupError(ModelsError):
    pass


class RateLimited(ModelsError):
    def __init__(self, until):
        super().__init__("Artificial Analysis quota reached. Refresh is paused until the quota resets; cached models remain available.")
        self.until = until


@contextmanager
def deadline(seconds):
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_delay, previous_interval = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()

    def expired(signum, frame):
        raise ModelsError("Artificial Analysis request timed out. Cached models remain available.")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, min(seconds, previous_delay) if previous_delay else seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_delay:
            signal.setitimer(signal.ITIMER_REAL, max(0.001, previous_delay - (time.monotonic() - started)), previous_interval)


class HTTPFetcher:
    def __call__(self, url, key):
        # No generic URL opener, redirect handler, proxy, or user-controlled host.
        page = url.removeprefix(ENDPOINT)
        if not url.startswith(ENDPOINT) or not page.isdecimal() or not 1 <= int(page) <= MAX_PAGES:
            raise ModelsError("Invalid Artificial Analysis endpoint.")
        connection = http.client.HTTPSConnection(HOST, timeout=FETCH_SECONDS)
        try:
            with deadline(FETCH_SECONDS):
                connection.request("GET", "/api/v2/language/models/free?page=" + page, headers={
                    "x-api-key": key, "Accept": "application/json", "Accept-Encoding": "identity",
                    "User-Agent": "Tern-Models/1.0",
                })
                response = connection.getresponse()
                headers = {name.lower(): value for name, value in response.getheaders()}
                # Error bodies can contain credentials; never read or reflect them.
                if response.status != 200:
                    return response.status, headers, b""
                if headers.get("content-encoding", "identity").lower() != "identity":
                    raise ModelsError("Artificial Analysis returned unsupported compressed data.")
                body = response.read(MAX_PAGE_BYTES + 1)
                if len(body) > MAX_PAGE_BYTES:
                    raise ModelsError("Artificial Analysis response exceeds the size limit.")
                return response.status, headers, body
        finally:
            connection.close()


def empty_snapshot():
    return {"models": [], "fetched_at": None, "index_version": None}


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def required_text(value, limit=300):
    if not isinstance(value, str) or not value.strip() or len(value) > limit or CONTROLS.search(value):
        raise ModelsError("Artificial Analysis returned malformed model data.")
    return value.strip()


def normalize(row):
    if not isinstance(row, dict):
        raise ModelsError("Artificial Analysis returned malformed model data.")
    creator = row.get("model_creator")
    if "model_creator" not in row or (creator is not None and not isinstance(creator, dict)):
        raise ModelsError("Artificial Analysis returned malformed creator data.")
    slug = required_text(row.get("slug"), 256)
    if not SLUG.fullmatch(slug):
        raise ModelsError("Artificial Analysis returned an invalid model slug.")
    result = {
        "id": required_text(row.get("id")), "name": required_text(row.get("name")),
        "slug": slug, "creator": required_text(creator.get("name")) if creator is not None else "Unknown creator",
        "creator_id": required_text(creator.get("id")) if creator is not None else "",
        "url": "https://artificialanalysis.ai/models/" + slug,
    }
    if "release_date" not in row:
        raise ModelsError("Artificial Analysis omitted model release metadata.")
    released = row["release_date"]
    if released is not None:
        if not isinstance(released, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", released):
            raise ModelsError("Artificial Analysis returned an invalid release date.")
        try:
            date.fromisoformat(released)
        except ValueError:
            raise ModelsError("Artificial Analysis returned an invalid release date.") from None
        result["release_date"] = released
    for field, (group, source) in METRICS.items():
        values = row.get(group)
        if not isinstance(values, dict) or source not in values:
            raise ModelsError("Artificial Analysis omitted required model metrics.")
        value = values[source]
        if value is not None:
            if not number(value) or (group != "evaluations" and value < 0):
                raise ModelsError("Artificial Analysis returned an invalid model metric.")
            result[field] = value
    return result


def quota_reset(headers, now):
    headers = {name.lower(): value for name, value in headers.items()}
    candidates = []
    retry = headers.get("retry-after", "")
    try:
        seconds = float(retry)
        if math.isfinite(seconds) and seconds >= 0:
            candidates.append(now + seconds)
    except (ValueError, TypeError):
        try:
            candidates.append(parsedate_to_datetime(retry).timestamp())
        except (ValueError, TypeError, OverflowError):
            pass
    for name in ("x-ratelimit-reset", "ratelimit-reset"):
        try:
            reset = float(headers.get(name, ""))
            if math.isfinite(reset) and reset >= 0:
                # X-RateLimit-Reset is an epoch; RateLimit-Reset is delay seconds.
                candidates.append(reset if name.startswith("x-") else now + reset)
        except (ValueError, TypeError):
            pass
    future = [value for value in candidates if value > now]
    return max(future) if future else now + 86400


def fetch_snapshot(fetcher, key, now):
    models, identities, slugs = [], set(), set()
    expected = None
    total_bytes = 0
    for page in range(1, MAX_PAGES + 1):
        status, headers, body = fetcher(ENDPOINT + str(page), key)
        if status in (401, 403):
            raise SetupError("Artificial Analysis rejected the API key. Replace it using the key button, then Refresh.")
        if status == 429:
            raise RateLimited(quota_reset(headers, now))
        if 300 <= status < 400:
            raise ModelsError("Artificial Analysis redirected the request. Redirects are blocked to protect the API key.")
        if status != 200:
            raise ModelsError("Artificial Analysis is unavailable. Cached models remain available; try Refresh later.")
        if not isinstance(body, bytes) or len(body) > MAX_PAGE_BYTES:
            raise ModelsError("Artificial Analysis response exceeds the size limit.")
        total_bytes += len(body)
        if total_bytes > MAX_CACHE_BYTES:
            raise ModelsError("Artificial Analysis results exceed the size limit.")
        try:
            payload = json.loads(body)
        except (ValueError, UnicodeError):
            raise ModelsError("Artificial Analysis returned invalid JSON.") from None
        if not isinstance(payload, dict) or payload.get("tier") not in ("free", "pro", "commercial"):
            raise ModelsError("Artificial Analysis returned an invalid response.")
        pagination = payload.get("pagination")
        version = payload.get("intelligence_index_version")
        rows = payload.get("data")
        if not isinstance(pagination, dict) or not isinstance(rows, list) or not number(version) or version <= 0:
            raise ModelsError("Artificial Analysis returned malformed pagination or index metadata.")
        current, size, total, more = (pagination.get(name) for name in ("page", "page_size", "total_pages", "has_more"))
        if (type(current) is not int or current != page or type(size) is not int or not 1 <= size <= MAX_MODELS
                or type(total) is not int or not 1 <= total <= MAX_PAGES or page > total
                or type(more) is not bool or more != (page < total)
                or len(rows) > size or (more and len(rows) != size) or (total > 1 and not rows)):
            raise ModelsError("Artificial Analysis returned incomplete pagination.")
        metadata = (size, total, version, payload["tier"])
        if expected is not None and metadata != expected:
            raise ModelsError("Artificial Analysis pagination changed during refresh; cached models remain available.")
        expected = metadata
        for row in rows:
            model = normalize(row)
            if model["id"] in identities or model["slug"] in slugs:
                raise ModelsError("Artificial Analysis returned duplicate models across pages.")
            identities.add(model["id"])
            slugs.add(model["slug"])
            models.append(model)
            if len(models) > MAX_MODELS:
                raise ModelsError("Artificial Analysis returned too many models.")
        if not more:
            return {"models": models, "fetched_at": now, "index_version": format(version, "g")}
    raise ModelsError("Artificial Analysis pagination exceeds the request limit.")


def safe_path(value):
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise ModelsError("Models cache and key paths must be absolute host paths.")
    path = Path(value).resolve()
    if path == REPO or REPO in path.parents:
        raise ModelsError("Models cache and credentials must be stored outside the plugin repository.")
    return path


def validate_key(value):
    key = value.strip() if isinstance(value, str) else ""
    if not key or len(key) > MAX_KEY_BYTES or any(not 33 <= ord(char) <= 126 for char in key):
        raise SetupError("Invalid Artificial Analysis API key format. Enter only the raw key.")
    return key


def read_key(path, environ):
    try:
        with path.open("rb") as file:
            raw = file.read(MAX_KEY_BYTES + 1)
        if len(raw) > MAX_KEY_BYTES:
            raise SetupError("Artificial Analysis key file is too large. Store only the raw API key, then Refresh.")
        key = raw.decode("ascii")
    except FileNotFoundError:
        key = environ.get("AA_API_KEY")
        if not key:
            raise SetupError("Add an Artificial Analysis API key using the key button, then Refresh.") from None
    except (OSError, UnicodeError):
        raise SetupError("Cannot read the Artificial Analysis key file. Check its permissions and raw key contents, then Refresh.") from None
    return validate_key(key)


def save_key(path, value):
    key = validate_key(value)
    try:
        write_atomic(path, key.encode("ascii"), ".aa-key-")
    except Exception:
        raise ModelsError("Could not save the Artificial Analysis API key. Check the key directory permissions and try again.") from None


def read_cache(path):
    try:
        with path.open("rb") as file:
            raw = file.read(MAX_CACHE_BYTES + 1)
        if len(raw) > MAX_CACHE_BYTES:
            raise ValueError
        state = json.loads(raw)
        snapshot = state["snapshot"]
        if state.get("version") != 1 or not isinstance(snapshot, dict) or not isinstance(snapshot.get("models"), list):
            raise ValueError
        if snapshot.get("fetched_at") is not None and (not number(snapshot["fetched_at"]) or snapshot["fetched_at"] < 0):
            raise ValueError
        if snapshot.get("index_version") is not None and not isinstance(snapshot["index_version"], str):
            raise ValueError
        if not number(state.get("retry_at", 0)) or len(snapshot["models"]) > MAX_MODELS:
            raise ValueError
        for row in snapshot["models"]:
            if not isinstance(row, dict):
                raise ValueError
            for field in ("id", "name", "slug", "creator", "url"):
                required_text(row.get(field))
            if row.get("creator_id") != "":
                required_text(row.get("creator_id"))
            if not SLUG.fullmatch(row["slug"]) or row["url"] != "https://artificialanalysis.ai/models/" + row["slug"]:
                raise ValueError
            for field in METRICS:
                if field in row and not number(row[field]):
                    raise ValueError
        return state, None
    except FileNotFoundError:
        return {"version": 1, "snapshot": empty_snapshot(), "retry_at": 0}, None
    except (OSError, ValueError, TypeError, KeyError, ModelsError):
        return {"version": 1, "snapshot": empty_snapshot(), "retry_at": 0}, "Models cache could not be read. Refresh to fetch a complete snapshot."


def write_cache(path, state):
    raw = json.dumps(state, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode()
    if len(raw) > MAX_CACHE_BYTES:
        raise ModelsError("Models cache exceeds the size limit.")
    write_atomic(path, raw, ".models-")


def write_atomic(path, raw, prefix):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = None
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=prefix, dir=path.parent)
        with os.fdopen(descriptor, "wb") as file:
            os.fchmod(file.fileno(), 0o600)
            file.write(raw)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)


def execute(request, *, fetcher=None, clock=time.time, environ=None):
    state = {"version": 1, "snapshot": empty_snapshot(), "retry_at": 0}
    error, setup = None, False
    now = clock()
    api_key = request.pop("api_key", None) if isinstance(request, dict) else None
    try:
        if not isinstance(request, dict) or request.get("action") not in ("snapshot", "refresh", "save_key"):
            raise ModelsError("Invalid Models worker request.")
        cache = safe_path(request.get("cache"))
        key_path = safe_path(request.get("key_path"))
        if cache == key_path:
            raise ModelsError("Models cache and key file must have different paths.")
        state, error = read_cache(cache)
        if request["action"] == "save_key":
            save_key(key_path, api_key)
            return {"ok": True, "key_saved": True, "snapshot": state["snapshot"], "error": None, "setup": False,
                    "retry_at": state.get("retry_at", 0),
                    "refresh_after_seconds": max(REFRESH_SECONDS, state.get("retry_at", 0) - now)}
        key = read_key(key_path, os.environ if environ is None else environ)
        if state.get("retry_at", 0) > now:
            raise RateLimited(state["retry_at"])
        fetched = state["snapshot"].get("fetched_at")
        fresh = number(fetched) and 0 <= now - fetched < REFRESH_SECONDS
        if request["action"] == "refresh" and (request.get("force") is True or not fresh):
            try:
                with deadline(TOTAL_SECONDS):
                    snapshot = fetch_snapshot(fetcher or HTTPFetcher(), key, now)
            except RateLimited as limited:
                state["retry_at"] = limited.until
                try:
                    write_cache(cache, state)
                except OSError:
                    raise ModelsError("Artificial Analysis quota reached, but its cooldown could not be saved. Check cache permissions before refreshing.") from None
                raise
            next_state = {"version": 1, "snapshot": snapshot, "retry_at": 0}
            try:
                write_cache(cache, next_state)
            except OSError:
                raise ModelsError("Models were fetched but the cache could not be saved. Check cache directory permissions.") from None
            state, error = next_state, None
    except SetupError as problem:
        error, setup = str(problem), True
    except ModelsError as problem:
        error = str(problem)
    except Exception:
        # Never reflect exception text: transports/filesystem errors can contain a key.
        error = "Models request failed. Check your network and cache permissions, then Refresh; cached models remain available."
    finally:
        api_key = None
    delay = REFRESH_SECONDS
    fetched = state["snapshot"].get("fetched_at")
    if error is None and number(fetched):
        delay = max(60, fetched + REFRESH_SECONDS - now)
    if state.get("retry_at", 0) > now:
        delay = max(delay, state["retry_at"] - now)
    return {"ok": error is None, "key_saved": False, "snapshot": state["snapshot"], "error": error, "setup": setup,
            "retry_at": state.get("retry_at", 0), "refresh_after_seconds": delay}


def main():
    try:
        raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
        if len(raw) > MAX_REQUEST:
            raise ValueError
        request = json.loads(raw)
        del raw
        result = execute(request)
    except Exception:
        result = {"ok": False, "key_saved": False, "snapshot": empty_snapshot(), "error": "Invalid Models worker input.",
                  "setup": False, "retry_at": 0}
    sys.stdout.write(json.dumps(result, ensure_ascii=True, allow_nan=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
