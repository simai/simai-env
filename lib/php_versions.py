#!/usr/bin/env python3
"""PHP versions of the host for `php list`: installed versions, the sites on
each, package updates waiting in the apt index, and the versions that can be
installed. Reads only; the apt index is as fresh as the last `apt-get update`.

Usage: php_versions.py OUTPUT NATIVE   (OUTPUT json|human; NATIVE e.g. 8.3)
       php_versions.py sites VERSION   (domains on this version, one a line)
       php_versions.py packages VERSION (installed packages of this version)
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ETC_PHP = Path("/etc/php")
NGINX = Path("/etc/nginx/sites-available")
VERSION = re.compile(r"^[5-9]\.[0-9]$")


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def installed():
    if not ETC_PHP.is_dir():
        return []
    return sorted((p.parent.name for p in ETC_PHP.glob("*/fpm") if VERSION.match(p.parent.name)),
                  key=lambda v: tuple(map(int, v.split("."))))


def site_versions():
    sites = {}
    for cfg in sorted(NGINX.glob("*.conf")):
        try:
            head = cfg.read_text(errors="replace")[:4000]
        except OSError:
            continue
        m = re.search(r"^# simai-php: *([0-9.]+) *$", head, re.M)
        if m:
            sites.setdefault(m.group(1), []).append(cfg.stem)
    return sites


def packages(version):
    out = run("dpkg-query", "-W", "-f", "${Package}\t${Version}\t${db:Status-Abbrev}\n", f"php{version}-*")
    return {p: v for p, v, s in (l.split("\t") for l in out.splitlines() if l.count("\t") == 2)
            if s.startswith("ii")}


def candidates(names):
    """Installed and candidate versions from the apt index, one call."""
    out = run("apt-cache", "policy", *names) if names else ""
    res, pkg = {}, None
    for line in out.splitlines():
        if not line.startswith(" "):
            pkg = line.rstrip(":")
        elif pkg and line.strip().startswith("Candidate:"):
            res[pkg] = line.split(":", 1)[1].strip()
    return res


def active(unit):
    return run("systemctl", "is-active", unit).strip() == "active"


def cli_default():
    try:
        target = Path("/etc/alternatives/php").resolve().name
    except OSError:
        return None
    m = re.match(r"^php([0-9]+\.[0-9]+)$", target)
    return m.group(1) if m else None


def installable(have):
    out = run("apt-cache", "pkgnames")
    found = {m.group(1) for m in (re.match(r"^php([0-9]+\.[0-9]+)-fpm$", l) for l in out.splitlines()) if m}
    return sorted(found - set(have), key=lambda v: tuple(map(int, v.split("."))))


def main(argv):
    if argv[0] in ("sites", "packages"):
        for item in site_versions().get(argv[1], []) if argv[0] == "sites" else sorted(packages(argv[1])):
            print(item)
        return
    output, native = argv[0], argv[1]
    sites, cli, rows = site_versions(), cli_default(), []
    for v in installed():
        pkgs = packages(v)
        cand = candidates(sorted(pkgs))
        updates = sorted(p for p, have in pkgs.items() if cand.get(p) not in (None, "(none)", have))
        rows.append({"version": v, "fpm_active": active(f"php{v}-fpm"), "sites": sites.get(v, []),
                     "native": v == native, "cli_default": v == cli,
                     "package_version": pkgs.get(f"php{v}-fpm"), "updates": updates,
                     "removable": not sites.get(v) and v != native and v != cli})
    data = {"schema": "simai-php/1", "native": native or None, "versions": rows,
            "installable": installable([r["version"] for r in rows])}
    if output == "json":
        print(json.dumps(data))
        return
    print(f"{'Version':<9}{'FPM':<10}{'Sites':<7}{'Updates':<9}Notes")
    for r in rows:
        notes = ", ".join(n for n, on in (("system", r["native"]), ("php command", r["cli_default"])) if on)
        print(f"{r['version']:<9}{'active' if r['fpm_active'] else 'inactive':<10}{len(r['sites']):<7}"
              f"{len(r['updates']):<9}{notes}")
    if data["installable"]:
        print(f"Can install: {', '.join(data['installable'])}")


if __name__ == "__main__":
    main(sys.argv[1:])
