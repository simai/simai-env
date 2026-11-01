#!/usr/bin/env python3
"""Answer of `self profiles`: the enabled site profiles with the `site add`
arguments each one takes, their values and defaults, so a site wizard can be
built from the server instead of a copy of these rules.

Usage: site_profiles.py json|human
Reads profiles/*.profile.sh (plain KEY="value" lines), the allowlist
/etc/simai-env/profiles.enabled and the installed PHP versions.
"""
import json
import os
import re
import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROFILES = Path(os.environ.get("SIMAI_PROFILES_DIR", ROOT / "profiles"))
ENABLED = Path("/etc/simai-env/profiles.enabled")

DOMAIN = r"^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?)+$"
# WordPress and Bitrix run on MySQL only.
PGSQL_PROFILES = {"generic", "laravel"}
# Arguments that only some profiles take.
OWN_ARGS = {
    "redirect": [
        {"name": "redirect-to", "required": True, "pattern": r"^https?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$",
         "description": "the origin every request goes to, such as https://example.com"},
        {"name": "redirect-code", "required": False, "values": ["301", "302", "307", "308"], "default": "301"},
        {"name": "redirect-path", "required": False, "values": ["keep", "drop"], "default": "keep",
         "description": "keep: path and query go along; drop: every request goes to the target's root page"},
    ],
    "proxy": [
        {"name": "upstream-port", "required": True, "pattern": r"^[1-9][0-9]{0,4}$",
         "description": "port of the service on 127.0.0.1 (1-65535, not 80 or 443); nothing outside this host"},
        {"name": "upstream-path", "required": False, "pattern": r"^/[A-Za-z0-9._~/-]{0,200}$", "default": "/"},
        {"name": "websockets", "required": False, "values": ["yes", "no"], "default": "no"},
    ],
    "node": [
        {"name": "app-port", "required": False, "pattern": r"^[1-9][0-9]{3,4}$",
         "description": "port of the application service; a free one is chosen when empty"},
    ],
    "bitrix": [
        {"name": "bitrix-files", "required": False, "values": ["none", "setup", "restore"], "default": "none",
         "description": "setup: bitrixsetup.php, restore: restore.php in the site root; none until needed"},
    ],
}


def read_profile(path):
    meta = {}
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"^PROFILE_([A-Z0-9_]+)=(.*)$", line.strip())
        if not m:
            continue
        raw = m.group(2).strip()
        try:
            meta[m.group(1)] = shlex.split(raw[1:-1]) if raw.startswith("(") else (shlex.split(raw) or [""])[0]
        except ValueError:
            continue
    return meta


def php_versions():
    found = [p.parent.parent.name for p in Path("/etc/php").glob("*/fpm/php-fpm.conf")] if Path("/etc/php").is_dir() else []
    return sorted({v for v in found if re.fullmatch(r"\d\.\d", v)}, key=lambda v: tuple(map(int, v.split("."))))


def key(v):
    return tuple(int(x) for x in v.split("."))


def describe(pid, meta, installed, pgsql):
    args = [{"name": "domain", "required": True, "pattern": DOMAIN}]
    php = None
    if meta.get("REQUIRES_PHP") == "yes":
        allowed = [v for v in meta.get("ALLOWED_PHP_VERSIONS") or [] if v]
        low = meta.get("ALLOWED_PHP_MIN_VERSION") or ""
        versions = [v for v in installed if (not allowed or v in allowed) and (not low or key(v) >= key(low))]
        php = {"versions": versions, "min": low or None, "default": versions[-1] if versions else None}
        args.append({"name": "php", "required": False, "values": versions, "default": php["default"]})
    db_mode = meta.get("REQUIRES_DB") or "no"
    if db_mode in ("optional", "required"):
        args.append({"name": "create-db", "required": False, "values": ["yes", "no"] if db_mode == "optional" else ["yes"],
                     "default": "yes"})
        args.append({"name": "db-engine", "required": False, "values": ["mysql", "pgsql"] if pgsql and pid in PGSQL_PROFILES else ["mysql"],
                     "default": meta.get("DB_ENGINE") or "mysql"})
    args += OWN_ARGS.get(pid, [])
    args.append({"name": "owner", "required": False, "pattern": r"^[a-z][a-z0-9_-]{0,31}$"})
    if pid not in ("redirect", "proxy"):
        args.append({"name": "backup", "required": False, "values": ["yes", "no"], "default": "yes",
                     "description": "a daily data backup from the start"})
    return {"id": pid, "title": meta.get("TITLE") or pid, "php": php, "db": db_mode,
            "cron": meta.get("SUPPORTS_CRON") == "yes", "queue": meta.get("SUPPORTS_QUEUE") == "yes",
            "alias": meta.get("IS_ALIAS") == "yes", "args": args}


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "human"
    try:
        enabled = {l.strip() for l in ENABLED.read_text().splitlines() if l.strip() and not l.lstrip().startswith("#")}
    except OSError:
        enabled = None  # no allowlist: every bundled profile is enabled
    installed, pgsql = php_versions(), Path("/usr/lib/postgresql").is_dir()
    profiles = []
    for path in sorted(PROFILES.glob("*.profile.sh")):
        pid = path.name[:-len(".profile.sh")]
        if enabled is None or pid in enabled:
            profiles.append(describe(pid, read_profile(path), installed, pgsql))
    if mode == "json":
        print(json.dumps({"schema": "simai-site-profiles/1", "php_installed": installed, "profiles": profiles},
                         ensure_ascii=False))
        return
    for p in profiles:
        own = ", ".join(a["name"] for a in p["args"] if a["name"] not in ("domain", "owner", "backup"))
        print(f"{p['id']:<10} {p['title']}" + (f"  [{own}]" if own else ""))


if __name__ == "__main__":
    main()
