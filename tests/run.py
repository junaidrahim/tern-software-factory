#!/usr/bin/env python3
"""Run the real plugin halves against a deterministic Tern API harness."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = {
    name.upper().replace("/", "_"): (root / f"{name}.luau").read_text()
    for name in ("tracking", "limits", "news/sources", "news/controller", "news/page", "models/controller", "models/page", "github/controller", "github/page", "repositories/section", "host", "window")
}
with tempfile.TemporaryDirectory() as directory:
    for name in ("behavior", "news", "models", "models_controller", "github", "repositories", "repository_routes"):
        harness = (root / "tests" / f"{name}.luau").read_text()
        for marker, source in sources.items():
            harness = harness.replace(f"-- {marker}_SOURCE", source)
        script = Path(directory) / f"{name}.luau"
        script.write_text(harness)
        subprocess.run([os.environ.get("LUAU", "luau"), str(script)], check=True)
