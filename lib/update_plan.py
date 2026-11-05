#!/usr/bin/env python3
"""Answer of `self update-plan`: what `self update --target T` would change.

Reads its inputs from the environment (self.sh collects them): TARGET,
CURRENT, AVAILABLE, NOTES_URL, BLOCKED, DOMAIN, CHANGELOG_FILE (the remote
changelog, env target only), STATUS_FILE (site-status.json) and OUTPUT (json|human).
"""
import json
import os
import re

env = os.environ


def key(version):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", version or "")
    return tuple(int(x) for x in m.groups()) if m else None


def answering(path):
    """Sites whose last check answered below 500: the ones checked after an update."""
    try:
        sites = json.load(open(path)).get("sites", {})
    except (OSError, ValueError, AttributeError):
        return []
    return sorted(d for d, s in sites.items()
                  if isinstance(s, dict) and isinstance(s.get("http"), int) and 0 < s["http"] < 500)


def main():
    target, current, available = env["TARGET"], env.get("CURRENT", ""), env.get("AVAILABLE", "")
    domain, blocked = env.get("DOMAIN", ""), env.get("BLOCKED", "") or None
    newer = bool(key(available) and (key(current) is None or key(available) > key(current)))
    notes = []
    if target == "env":
        if newer:
            try:
                changelog = open(env.get("CHANGELOG_FILE", ""), errors="replace").read()
            except OSError:
                changelog = ""
            for m in re.finditer(r"^## (\d+\.\d+\.\d+)[^\n]*\n(.*?)(?=^## |\Z)", changelog, re.S | re.M):
                if key(current) is None or key(current) < key(m.group(1)) <= key(available):
                    notes.append({"version": m.group(1), "text": m.group(2).strip()[:8000]})
        checks = answering(env.get("STATUS_FILE", ""))
        restarts = []
        backup = "simai-env scripts (/root/simai-backups)"
        backup_item = {"kind": "env_scripts", "path": "/root/simai-backups"}
        rollback_kind = "env_release"
        rollback = ("the previous simai-env release, from the archive taken before the update, if a checked "
                    "site stops answering; host migrations are not undone")
    else:
        checks = [domain] if domain else []
        restarts = ["PHP-FPM pool and queue workers of " + domain] if domain else []
        backup = "panel data (backup data)" if domain else None
        backup_item = {"kind": "panel_data", "path": f"/var/backups/simai/{domain}"} if domain else None
        rollback_kind = "panel_release"
        rollback = ("the previous panel release, if the new one does not answer its health path; "
                    "the database is not rolled back")
    data = {"schema": "simai-update-plan/1", "target": target, "current": current or None,
            "available": available or None, "update_available": newer and blocked is None, "blocked": blocked,
            "notes": notes, "notes_url": env.get("NOTES_URL") or None, "backup": backup, "restarts": restarts,
            "checks": checks, "rollback": rollback,
            # Codes for the panel to translate; the texts above stay for older panels.
            "backup_item": backup_item,
            "restart_items": [{"kind": "php_fpm_pool", "target": domain}, {"kind": "queue_workers", "target": domain}]
            if target == "panel" and domain else [],
            "rollback_kind": rollback_kind}
    if env.get("OUTPUT") == "json":
        print(json.dumps(data, ensure_ascii=False))
        return
    rows = [("Target", target), ("Installed", current or "-"),
            ("Available", (available or "-") + ("  (update available)" if data["update_available"] else ""))]
    if blocked:
        rows.append(("Blocked", blocked))
    rows += [("Backup", backup or "-"), ("Restarts", ", ".join(restarts) or "nothing; sites keep running"),
             ("Checked", ", ".join(checks) or "-"), ("Rollback", rollback)]
    for name, value in rows:
        print(f"{name + ':':<12} {value}")
    for note in notes:
        print(f"\n## {note['version']}\n{note['text']}")
    if data["notes_url"]:
        print(f"\nRelease notes: {data['notes_url']}")


if __name__ == "__main__":
    main()
