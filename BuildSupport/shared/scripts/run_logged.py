#!/usr/bin/env python3
"""Run one command with its output in a private log and print a JSON receipt.

Usage: run_logged.py --log FILE --label NAME --timeout SECONDS -- COMMAND...
Exits with the command's status, or 124 on timeout. Refuses an existing log.
On failure the receipt lists recent error lines, skipping likely secrets.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--log", required=True, type=Path)
parser.add_argument("--label", required=True)
parser.add_argument("--timeout", required=True, type=float)
parser.add_argument("command", nargs=argparse.REMAINDER)
arguments = parser.parse_args()
command = arguments.command[1:] if arguments.command[:1] == ["--"] else arguments.command
if not command:
    parser.error("a command is required after --")

started = time.monotonic()
descriptor = os.open(arguments.log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "wb") as log:
    try:
        status = subprocess.run(
            command, stdout=log, stderr=subprocess.STDOUT,
            timeout=arguments.timeout, check=False,
        ).returncode
    except subprocess.TimeoutExpired:
        status = 124

receipt = {
    "label": arguments.label,
    "exit_code": status,
    "elapsed_seconds": round(time.monotonic() - started, 2),
    "log": str(arguments.log),
    "log_bytes": arguments.log.stat().st_size,
}
if status:
    lines = arguments.log.read_text(encoding="utf-8", errors="replace").splitlines()
    receipt["diagnostics"] = [
        line[:300] for line in lines
        if re.search(r"error:|failed|failure|fatal|warning:|timed out", line, re.I)
        and not re.search(r"token|password|secret|authorization|<key>|<string>|BEGIN .*KEY", line, re.I)
    ][-8:]
print(json.dumps(receipt))
sys.exit(status)
