#!/usr/bin/env python3
"""Refresh /var/lib/simai-env/site-status.json: whether each site answers and
how much disk it uses. Run every few minutes by cron as root; host_describe.py
reads the file, so self describe never waits for sites.

Usage: site_status.py [--disk-every MINUTES]

The answer is the HTTP status of the site's health path (.simai/app.json
health.path, else /) asked through nginx on 127.0.0.1, without following
redirects. Disk is the size of the site directory, measured at most every
--disk-every minutes (default 60), because it reads every file.
"""
from __future__ import annotations

import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

NGINX = Path("/etc/nginx/sites-available")
STATUS = Path(os.environ.get("SIMAI_SITE_STATUS", "/var/lib/simai-env/site-status.json"))


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sites() -> dict[str, dict]:
    out = {}
    for conf in sorted(NGINX.glob("*.conf")) if NGINX.is_dir() else []:
        meta = {}
        for line in conf.read_text(errors="replace").splitlines():
            m = re.match(r"^# simai-([a-z-]+):\s*(.*)$", line)
            if m:
                meta[m.group(1)] = m.group(2)
        if meta.get("domain") and meta.get("root") and re.fullmatch(r"[a-z0-9.-]+", meta["domain"]):
            out[meta["domain"]] = meta
    return out


def health_path(root: Path) -> str:
    for base in (root / "current", root):
        try:
            path = json.loads((base / ".simai" / "app.json").read_text()).get("health", {}).get("path")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(path, str) and re.fullmatch(r"/[A-Za-z0-9._~/-]{0,200}", path):
            return path
        return "/"
    return "/"


def probe(domain: str, path: str) -> int | None:
    try:
        conn = http.client.HTTPConnection("127.0.0.1", 80, timeout=5)
        conn.request("GET", path, headers={"Host": domain, "User-Agent": "simai-site-status"})
        code = conn.getresponse().status
        conn.close()
        return code
    except (OSError, http.client.HTTPException):
        return None


def disk(root: Path) -> int | None:
    try:
        out = subprocess.run(["du", "-sb", "--", str(root)], capture_output=True, text=True, timeout=300)
        return int(out.stdout.split()[0])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


def main() -> int:
    every = 60
    if len(sys.argv) == 3 and sys.argv[1] == "--disk-every" and sys.argv[2].isdigit():
        every = int(sys.argv[2])
    try:
        old = json.loads(STATUS.read_text()).get("sites", {})
    except (OSError, ValueError, AttributeError):
        old = {}
    result = {}
    for domain, meta in sites().items():
        root = Path(meta["root"])
        path = health_path(root)
        entry = {"http": probe(domain, path), "path": path, "checked_at": now()}
        previous = old.get(domain, {}).get("disk") if isinstance(old.get(domain), dict) else None
        fresh = isinstance(previous, dict) and isinstance(previous.get("measured"), (int, float)) \
            and time.time() - previous["measured"] < every * 60
        entry["disk"] = previous if fresh else {"bytes": disk(root), "checked_at": now(), "measured": time.time()}
        result[domain] = entry
    STATUS.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATUS.parent, prefix=".site-status.")
    with os.fdopen(fd, "w") as stream:
        json.dump({"schema": "simai-site-status/1", "generated_at": now(), "sites": result}, stream, indent=2)
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATUS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
