#!/usr/bin/env python3
"""Run the real plugin halves against a deterministic Tern API harness."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
harness = (root / "tests/behavior.luau").read_text()
for half in ("tracking", "limits", "host", "window"):
    harness = harness.replace(f"-- {half.upper()}_SOURCE", (root / f"{half}.luau").read_text())
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / "behavior.luau"
    script.write_text(harness)
    subprocess.run([os.environ.get("LUAU", "luau"), str(script)], check=True)
