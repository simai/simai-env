#!/usr/bin/env python3
"""Timed changes: a change that undoes itself unless it is confirmed.

begin KIND DOMAIN WINDOW FILE...  copy the files (and note the missing ones),
                                  print the new change id and its deadline
confirm ID                        keep the change, drop the saved copies
restore ID                        put the saved files back; prints the kind
status ID [json]                  simai-change/1
pending KIND                      the pending change of a kind, if any
expired                           ids of pending changes past their deadline

State: /var/lib/simai-env/changes/<id>/{change.json, files/<n>}. One pending
change per kind, so two saved copies of the same files never overlap.
"""
import json
import os
import re
import secrets
import shutil
import sys
import time
from pathlib import Path

BASE = Path(os.environ.get("SIMAI_CHANGES_DIR", "/var/lib/simai-env/changes"))
CHANGE_ID = re.compile(r"^[a-f0-9]{12}$")
KINDS = {"firewall", "panel_access", "nginx_custom", "geo"}
KEEP_DAYS = 30


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def fail(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def load(change_id):
    if not CHANGE_ID.match(change_id):
        fail(f"Unknown change: {change_id}", 2)
    try:
        return json.loads((BASE / change_id / "change.json").read_text())
    except (OSError, ValueError):
        fail(f"Unknown change: {change_id}", 2)


def save(change):
    d = BASE / change["change_id"]
    tmp = d / "change.json.tmp"
    tmp.write_text(json.dumps(change, indent=1))
    os.chmod(tmp, 0o600)
    os.replace(tmp, d / "change.json")


def all_changes():
    if not BASE.is_dir():
        return []
    out = []
    for d in BASE.iterdir():
        if CHANGE_ID.match(d.name):
            try:
                out.append(json.loads((d / "change.json").read_text()))
            except (OSError, ValueError):
                continue
    return out


def prune():
    limit = time.time() - KEEP_DAYS * 86400
    for c in all_changes():
        if c.get("state") != "pending" and c.get("created_epoch", 0) < limit:
            shutil.rmtree(BASE / c["change_id"], ignore_errors=True)


def pending(kind):
    for c in all_changes():
        if c.get("kind") == kind and c.get("state") == "pending":
            return c
    return None


def public(c):
    return {"change_id": c["change_id"], "kind": c["kind"], "domain": c.get("domain"), "state": c["state"],
            "created_at": c["created_at"], "expires_at": c["expires_at"], "summary": c.get("summary", ""),
            "confirmed_at": c.get("confirmed_at"), "restored_at": c.get("restored_at")}


def main(argv):
    if not argv:
        fail(__doc__)
    action = argv[0]
    if action == "begin":
        kind, domain, window, summary, files = argv[1], argv[2], int(argv[3]), argv[4], argv[5:]
        if kind not in KINDS or not 30 <= window <= 600:
            fail("Invalid change kind or window")
        prune()
        other = pending(kind)
        if other:
            fail(f"Change {other['change_id']} is waiting for confirmation until {other['expires_at']}; "
                 f"confirm it (change confirm --id {other['change_id']}) or wait until it is undone", 3)
        BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
        change_id = secrets.token_hex(6)
        d = BASE / change_id
        (d / "files").mkdir(mode=0o700, parents=True)
        saved = []
        for n, path in enumerate(files):
            p = Path(path)
            if p.is_file():
                shutil.copy2(p, d / "files" / str(n))
                saved.append({"path": path, "existed": True})
            else:
                saved.append({"path": path, "existed": False})
        now = time.time()
        change = {"change_id": change_id, "kind": kind, "domain": domain or None, "state": "pending",
                  "created_epoch": now, "created_at": iso(now), "expires_epoch": now + window,
                  "expires_at": iso(now + window), "summary": summary[:300], "files": saved}
        save(change)
        print(change_id, change["expires_at"])
    elif action == "confirm":
        c = load(argv[1])
        if c["state"] == "restored":
            fail(f"Change {c['change_id']} was already undone at {c.get('restored_at')}; make it again", 4)
        if c["state"] == "pending":
            c.update(state="confirmed", confirmed_at=iso(time.time()))
            save(c)
            shutil.rmtree(BASE / c["change_id"] / "files", ignore_errors=True)
        print(c["kind"])
    elif action == "restore":
        c = load(argv[1])
        if c["state"] != "pending":
            print("")
            return
        d = BASE / c["change_id"] / "files"
        for n, f in enumerate(c["files"]):
            target = Path(f["path"])
            if f["existed"]:
                tmp = target.with_name(target.name + ".simai-restore")
                shutil.copy2(d / str(n), tmp)
                os.replace(tmp, target)
            else:
                target.unlink(missing_ok=True)
        c.update(state="restored", restored_at=iso(time.time()))
        save(c)
        shutil.rmtree(d, ignore_errors=True)
        print(c["kind"])
    elif action == "status":
        c = public(load(argv[1]))
        if len(argv) > 2 and argv[2] == "json":
            print(json.dumps({"schema": "simai-change/1", **c}))
        else:
            for k in ("change_id", "kind", "domain", "state", "summary", "created_at", "expires_at",
                      "confirmed_at", "restored_at"):
                if c.get(k):
                    print(f"{k:<13} {c[k]}")
    elif action == "pending":
        c = pending(argv[1])
        if c:
            print(json.dumps(public(c)))
    elif action == "expired":
        now = time.time()
        for c in all_changes():
            if c.get("state") == "pending" and c.get("expires_epoch", 0) <= now:
                print(c["change_id"])
    else:
        fail(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
