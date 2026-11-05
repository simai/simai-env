#!/usr/bin/env python3
"""Answers of backup storage-list and storage-copies (admin/commands/backup_storage.sh).

  backup_storage.py list STORAGE_DIR TEST_DIR OUTPUT
  backup_storage.py copies STORAGE OUTPUT   (stdin: "<domain>\t<backup>" lines)
"""
import json
import sys
from datetime import datetime
from pathlib import Path


def storages(storage_dir: Path, test_dir: Path) -> list[dict]:
    rows = []
    for f in sorted(storage_dir.glob("*.env")) if storage_dir.is_dir() else []:
        kv = dict(line.split("=", 1) for line in f.read_text().splitlines() if "=" in line)
        try:
            test = json.loads((test_dir / f"{f.stem}.json").read_text())
        except (OSError, ValueError):
            test = None
        key = kv.get("ACCESS_KEY_ID", "")
        try:
            keep = int(kv.get("KEEP") or 30)
        except ValueError:
            keep = 30
        rows.append({"name": f.stem, "type": kv.get("TYPE", "s3"), "bucket": kv.get("BUCKET"),
                     "endpoint": kv.get("ENDPOINT") or None, "region": kv.get("REGION") or None,
                     "prefix": kv.get("PREFIX") or None, "keep": keep, "default": kv.get("DEFAULT") == "yes",
                     "access_key_hint": ("…" + key[-4:]) if key else None,
                     "last_test": test if isinstance(test, dict) else None})
    return rows


def main() -> int:
    mode = sys.argv[1]
    if mode == "list":
        rows = storages(Path(sys.argv[2]), Path(sys.argv[3]))
        if sys.argv[4] == "json":
            print(json.dumps({"schema": "simai-backup-storages/1", "storages": rows}))
            return 0
        if not rows:
            print("No backup storages. Add one: simai-admin.sh backup storage-add --name s3 --bucket B "
                  "--endpoint URL --access-key-file F --secret-key-file F --confirm yes")
        for r in rows:
            t = r["last_test"]
            check = "never" if not t else ("ok " if t.get("ok") else "failed ") + str(t.get("at", ""))
            where = r["bucket"] + ("/" + r["prefix"] if r["prefix"] else "")
            print(f"{r['name']:<16}{'default' if r['default'] else '':<8} {where} at {r['endpoint'] or 'AWS'}, "
                  f"keeps {r['keep']}, key {r['access_key_hint']}, check: {check}")
        return 0
    if mode == "copies":
        storage, output = sys.argv[2], sys.argv[3]
        rows = []
        for line in sys.stdin:
            domain, _, backup = line.rstrip("\n").partition("\t")
            try:
                created = datetime.strptime(backup, "%Y%m%d-%H%M%S").strftime("%Y-%m-%dT%H:%M:%S")
            except ValueError:
                continue
            rows.append({"domain": domain, "backup": backup, "created_at": created})
        if output == "json":
            print(json.dumps({"schema": "simai-backup-copies/1", "storage": storage, "copies": rows}))
        else:
            for r in rows:
                print(f"{r['domain']:<32}{r['backup']}")
            print(f"{len(rows)} copies in {storage}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
