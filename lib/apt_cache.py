#!/usr/bin/env python3
"""Answers of slow apt queries (apt-cache policy, apt-get -s upgrade,
apt-cache pkgnames), kept until the package state changes.

The key of a kept answer is the query plus a stamp of what apt reads: the
dpkg status file, the package lists and the apt sources and preferences.
Installing, removing or upgrading a package, or refreshing the index,
changes the stamp, so a kept answer is never stale. Root only: the cache
lives under /var/lib/simai-env/cache/apt (0700).
"""
import hashlib
import json
import os
import subprocess
from pathlib import Path

CACHE = Path(os.environ.get("SIMAI_APT_CACHE_DIR", "/var/lib/simai-env/cache/apt"))
WATCH = ["/var/lib/dpkg/status", "/var/lib/apt/lists", "/etc/apt/sources.list", "/etc/apt/sources.list.d",
         "/etc/apt/preferences.d", "/etc/apt/apt.conf.d"]


def stamp(extra=()):
    parts = []
    for p in [*WATCH, *extra]:
        try:
            st = os.stat(p)
            parts.append(f"{p}:{st.st_mtime_ns}:{st.st_size}")
        except OSError:
            parts.append(f"{p}:-")
    return "|".join(parts)


def run(*cmd, timeout=120, watch=(), env=None, cwd=None):
    """stdout of cmd, from the cache when the package state (and the files
    in watch) are unchanged."""
    key = hashlib.sha256(json.dumps([list(cmd), stamp(watch)]).encode()).hexdigest()
    path = CACHE / f"{hashlib.sha256(json.dumps(list(cmd)).encode()).hexdigest()[:32]}.json"
    if os.geteuid() == 0:
        try:
            kept = json.loads(path.read_text())
            if kept.get("key") == key:
                return kept["out"]
        except (OSError, ValueError, KeyError):
            pass
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if os.geteuid() == 0 and out:
        try:
            CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"key": key, "out": out}))
            os.replace(tmp, path)
        except OSError:
            pass
    return out
