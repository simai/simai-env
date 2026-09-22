#!/usr/bin/env python3
"""Read an application's runtime requirements for simai-env.

Sources, in order of precedence:
  .simai/app.json   -- what the application declares (schema simai-app/1)
  composer.json     -- PHP version and ext-* requirements

Prints validated, tab-separated records for the shell (one per line):
  php_min <x.y[.z]> | php_ext <name> | package <apt-name> | executable <path>
  db_engine <mysql|pgsql> | db_version <major> | env <KEY> <value>
  scheduler <yes|no> | worker <name> <artisan args> <stop_timeout> <count>
  migrate <yes|no> | frame_ancestor <origin> | profile <id> | manifest <present|absent>
Exits 2 with a message on invalid input; nothing from the files reaches a
shell unvalidated.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
PACKAGE = re.compile(r"^[a-z0-9][a-z0-9+.-]{1,62}$")
EXE = re.compile(r"^/[A-Za-z0-9._/-]{1,200}$")
ENV_KEY = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
ENV_VALUE = re.compile(r"^[^\n\r\t]{0,500}$")
ARTISAN_ARGS = re.compile(r"^[a-z][a-z0-9:-]*( [A-Za-z0-9_=:.,/@-]+)*$")
ORIGIN = re.compile(r"^(https?://(\*\.)?[a-z0-9.-]+(:[0-9]{1,5})?|'self')$")
PHP_VERSION = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")
SECRET_KEY = re.compile(r"(PASS|PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE|CREDENTIALS?|_KEY|^KEY)(_|$)")


def fail(message: str) -> None:
    print(f"app manifest: {message}", file=sys.stderr)
    sys.exit(2)


def php_min_from_constraint(constraint: str) -> str | None:
    # First version in the constraint is the lower bound for ^, ~, >= forms.
    match = PHP_VERSION.search(constraint)
    if not match:
        return None
    major, minor, patch = match.groups()
    return f"{major}.{minor}.{patch}" if patch else f"{major}.{minor}"


def emit(*fields: object) -> None:
    print("\t".join(str(f) for f in fields))


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: app_manifest.py <project-root>")
    root = Path(sys.argv[1])
    manifest_path = root / ".simai" / "app.json"
    composer_path = root / "composer.json"
    manifest: dict = {}
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text())
        except (OSError, ValueError) as exc:
            fail(f"{manifest_path}: {exc}")
        if not isinstance(manifest, dict):
            fail(".simai/app.json must be an object")
        schema = manifest.get("schema", "simai-app/1")
        if schema != "simai-app/1":
            fail(f"unsupported schema {schema!r} (expected simai-app/1)")
        emit("manifest", "present")
    else:
        emit("manifest", "absent")

    composer: dict = {}
    if composer_path.is_file():
        try:
            composer = json.loads(composer_path.read_text())
        except (OSError, ValueError) as exc:
            fail(f"{composer_path}: {exc}")
    require = composer.get("require", {}) if isinstance(composer, dict) else {}
    if not isinstance(require, dict):
        require = {}

    profile = manifest.get("profile")
    if profile is not None:
        if not isinstance(profile, str) or not NAME.match(profile):
            fail("profile must be a profile id")
        emit("profile", profile)

    php = manifest.get("php") or php_min_from_constraint(str(require.get("php", "")))
    if php:
        if not isinstance(php, str) or not PHP_VERSION.fullmatch(php):
            fail("php must look like 8.4 or 8.4.1")
        emit("php_min", php)
    for key in sorted(require):
        if key.startswith("ext-"):
            ext = key[4:].lower()
            if not re.fullmatch(r"[a-z0-9_]{1,40}", ext):
                fail(f"invalid extension requirement {key!r}")
            emit("php_ext", ext)

    db = manifest.get("db", {})
    if not isinstance(db, dict):
        fail("db must be an object")
    engine = db.get("engine")
    if engine is not None:
        if engine not in ("mysql", "pgsql"):
            fail("db.engine must be mysql or pgsql")
        emit("db_engine", engine)
    version = db.get("version")
    if version is not None:
        if not re.fullmatch(r"[0-9]{1,2}", str(version)):
            fail("db.version must be a major version such as 17")
        emit("db_version", version)

    for field in ("packages", "executables", "frame_ancestors"):
        if not isinstance(manifest.get(field, []), list):
            fail(f"{field} must be a list")
    for item in manifest.get("packages", []):
        if not isinstance(item, str) or not PACKAGE.match(item):
            fail(f"invalid package name {item!r}")
        emit("package", item)
    for item in manifest.get("executables", []):
        if not isinstance(item, str) or not EXE.match(item) or ".." in item:
            fail(f"invalid executable path {item!r}")
        emit("executable", item)

    env = manifest.get("env", {})
    if not isinstance(env, dict):
        fail("env must be an object")
    for key, value in env.items():
        if not ENV_KEY.match(key):
            fail(f"invalid env key {key!r}")
        if SECRET_KEY.search(key) and key != "APP_KEY":
            fail(f"env key {key} looks like a secret; secrets do not belong in the manifest")
        if key == "APP_KEY":
            fail("APP_KEY is generated on the server and never read from the manifest")
        value = "true" if value is True else "false" if value is False else str(value)
        if not ENV_VALUE.match(value):
            fail(f"invalid value for env {key}")
        emit("env", key, value)

    scheduler = manifest.get("scheduler")
    if scheduler is not None:
        if not isinstance(scheduler, bool):
            fail("scheduler must be true or false")
        emit("scheduler", "yes" if scheduler else "no")

    workers = manifest.get("workers", [])
    if not isinstance(workers, list):
        fail("workers must be a list")
    seen = set()
    for worker in workers:
        if not isinstance(worker, dict):
            fail("each worker must be an object")
        name = worker.get("name", "default")
        if not isinstance(name, str) or not NAME.match(name) or name in seen:
            fail(f"invalid or duplicate worker name {name!r}")
        seen.add(name)
        command = worker.get("command", "queue:work")
        if not isinstance(command, str) or not ARTISAN_ARGS.match(command):
            fail(f"worker {name}: command must be artisan arguments such as 'queue:work database --tries=3'")
        stop = worker.get("stop_timeout", 60)
        count = worker.get("count", 1)
        if not isinstance(stop, int) or not 1 <= stop <= 604800:
            fail(f"worker {name}: stop_timeout must be 1..604800 seconds")
        if not isinstance(count, int) or not 1 <= count <= 16:
            fail(f"worker {name}: count must be 1..16")
        emit("worker", name, command, stop, count)

    migrate = manifest.get("migrate")
    if migrate is not None:
        if not isinstance(migrate, bool):
            fail("migrate must be true or false")
        emit("migrate", "yes" if migrate else "no")

    for origin in manifest.get("frame_ancestors", []):
        if not isinstance(origin, str) or not ORIGIN.match(origin):
            fail(f"invalid frame ancestor {origin!r}")
        emit("frame_ancestor", origin)
    return 0


if __name__ == "__main__":
    sys.exit(main())
