#!/usr/bin/env python3
"""Server software for `software list`: the components simai-env manages
(web server, databases, Redis, Node.js, tools) with their installed and
candidate versions, and the package updates of the whole system. Reads only;
the apt index is as fresh as the last `apt-get update` (`index_age_seconds`).

Usage: software_state.py OUTPUT          (OUTPUT json|human; simai-software/1)
       software_state.py upgradable [security]  (packages to upgrade, one a line)
       software_state.py node-sites      (domains with the node profile, one a line)
"""
import json
import re
import subprocess
import sys
import time
from pathlib import Path

NGINX = Path("/etc/nginx/sites-available")

# name, packages (first installed one counts), service, can `software install` add it
COMPONENTS = [
    ("nginx", ["nginx"], "nginx", False),
    ("mysql", ["percona-server-server", "mysql-server", "mariadb-server"], None, False),
    ("postgresql", ["postgresql"], "postgresql", True),
    ("redis", ["redis-server"], "redis-server", True),
    ("node", ["nodejs"], None, True),
    ("certbot", ["certbot"], None, False),
    ("apache", ["apache2"], "apache2", False),  # added by site apache
]


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def dpkg_versions(names):
    out = run("dpkg-query", "-W", "-f", "${Package}\t${Version}\t${db:Status-Abbrev}\n", *names)
    return {p: v for p, v, s in (l.split("\t") for l in out.splitlines() if l.count("\t") == 2)
            if s.startswith("ii")}


def candidates(names):
    out = run("apt-cache", "policy", *names) if names else ""
    res, pkg = {}, None
    for line in out.splitlines():
        if not line.startswith(" "):
            pkg = line.rstrip(":")
        elif pkg and line.strip().startswith("Candidate:"):
            res[pkg] = line.split(":", 1)[1].strip()
    return res


def upgradable():
    """Packages `apt-get upgrade` would change, from a simulation."""
    out = run("apt-get", "-s", "-o", "Debug::NoLocking=1", "upgrade")
    rows = []
    for line in out.splitlines():
        m = re.match(r"^Inst (\S+) \[([^\]]+)\] \((\S+) (.*?)\)", line)
        if m:
            rows.append({"name": m.group(1), "from": m.group(2), "to": m.group(3),
                         "security": "-security" in m.group(4)})
    held = re.search(r"^The following packages have been kept back:\n((?: .*\n)+)", out, re.M)
    return rows, sorted(held.group(1).split()) if held else []


def active(unit):
    return run("systemctl", "is-active", unit).strip() == "active"


def node_sites():
    sites = []
    for cfg in sorted(NGINX.glob("*.conf")):
        try:
            head = cfg.read_text(errors="replace")[:4000]
        except OSError:
            continue
        if re.search(r"^# simai-profile: *node *$", head, re.M):
            sites.append(cfg.stem)
    return sites


def index_age():
    lists = Path("/var/lib/apt/lists")
    try:
        newest = max((p.stat().st_mtime for p in lists.iterdir() if p.is_file()), default=0)
    except OSError:
        newest = 0
    return int(time.time() - newest) if newest else None


def mysql_service():
    for unit in ("mysql", "mariadb"):
        if run("systemctl", "list-unit-files", f"{unit}.service").count(f"{unit}.service"):
            return unit
    return None


def state():
    names = sorted({p for _, pkgs, _, _ in COMPONENTS for p in pkgs})
    have, cand = dpkg_versions(names), candidates(names)
    rows = []
    for name, pkgs, service, installable in COMPONENTS:
        pkg = next((p for p in pkgs if p in have), None)
        if name == "mysql" and pkg:
            service = mysql_service()
        version = have.get(pkg) if pkg else None
        candidate = cand.get(pkg or pkgs[0])
        candidate = None if candidate in (None, "(none)") else candidate
        rows.append({"name": name, "package": pkg, "installed": pkg is not None, "version": version,
                     "candidate": candidate, "update": bool(pkg and candidate and candidate != version),
                     "service": service if pkg else None,
                     "active": active(service) if pkg and service else None,
                     "installable": installable and pkg is None})
    node = next(r for r in rows if r["name"] == "node")
    node["sites"] = node_sites()
    ups, held = upgradable()
    reboot = Path("/run/reboot-required")
    try:
        reboot_pkgs = sorted(set(Path("/run/reboot-required.pkgs").read_text().split()))
    except OSError:
        reboot_pkgs = []
    return {"schema": "simai-software/1", "components": rows,
            "system": {"updates": len(ups), "security": sum(u["security"] for u in ups),
                       "packages": ups, "kept_back": held, "reboot_required": reboot.exists(),
                       "reboot_packages": reboot_pkgs, "index_age_seconds": index_age()}}


def main(argv):
    if argv[0] == "upgradable":
        for u in upgradable()[0]:
            if len(argv) < 2 or u["security"]:
                print(u["name"])
        return
    if argv[0] == "node-sites":
        for s in node_sites():
            print(s)
        return
    data = state()
    if argv[0] == "json":
        print(json.dumps(data))
        return
    print(f"{'Component':<12}{'Version':<34}{'Update':<8}Service")
    for r in data["components"]:
        version = r["version"] or ("not installed" + (", can install" if r["installable"] else ""))
        service = "" if r["active"] is None else ("active" if r["active"] else "inactive")
        print(f"{r['name']:<12}{version[:33]:<34}{'yes' if r['update'] else '':<8}{service}")
    s = data["system"]
    print(f"System updates: {s['updates']} (security {s['security']}), kept back: {len(s['kept_back'])}"
          f"{', reboot required' if s['reboot_required'] else ''}")


if __name__ == "__main__":
    main(sys.argv[1:])
