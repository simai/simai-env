#!/usr/bin/env python3
"""Machine-readable description of a simai-env host or site (read-only).

Usage: host_describe.py <simai-root> host
       host_describe.py <simai-root> site <domain>

Never reads secrets: db.env is filtered to engine/name/user/host/port, .env
files are not opened. Output schema: simai-host/1 and simai-site/1.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

NGINX = Path("/etc/nginx/sites-available")
STATE = Path("/etc/simai-env")
UNITS = Path("/etc/systemd/system")
DB_KEYS = {"DB_ENGINE", "DB_NAME", "DB_USER", "DB_HOST", "DB_PORT"}


def active(unit: str) -> str:
    try:
        out = subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def kv_file(path: Path, allowed: set[str] | None = None) -> dict:
    data = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if allowed is None or key in allowed:
                data[key] = value.strip()
    except OSError:
        pass
    return data


def metadata(domain: str) -> dict:
    meta = {}
    try:
        for line in (NGINX / f"{domain}.conf").read_text(errors="replace").splitlines():
            m = re.match(r"^# simai-([a-z-]+):\s*(.*)$", line)
            if m:
                meta[m.group(1)] = m.group(2)
    except OSError:
        pass
    return meta


def site_domains() -> list[str]:
    out = []
    for conf in sorted(NGINX.glob("*.conf")):
        if conf.stem == "000-catchall":
            continue
        if metadata(conf.stem).get("managed") == "yes" or "simai-domain" in conf.read_text(errors="replace"):
            out.append(conf.stem)
    return out


def manifest_summary(root: Path) -> dict | None:
    """Validated manifest fields only: the file lives in a directory the site
    user can write, so raw text is never passed on to readers or agents."""
    for base in (root / "current", root):
        path = base / ".simai" / "app.json"
        if not path.is_file():
            continue
        parser = Path(__file__).with_name("app_manifest.py")
        try:
            out = subprocess.run([sys.executable, str(parser), str(base)], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return {"path": str(path), "valid": False}
        if out.returncode != 0:
            return {"path": str(path), "valid": False}
        summary = {"path": str(path), "valid": True, "packages": [], "workers": [], "php_extensions": []}
        for line in out.stdout.splitlines():
            parts = line.split("\t")
            kind = parts[0]
            if kind == "db_engine":
                summary["db_engine"] = parts[1]
            elif kind == "php_min":
                summary["php_min"] = parts[1]
            elif kind == "php_ext":
                summary["php_extensions"].append(parts[1])
            elif kind == "package":
                summary["packages"].append(parts[1])
            elif kind == "worker":
                summary["workers"].append({"name": parts[1], "command": parts[2], "stop_timeout": int(parts[3]), "count": int(parts[4])})
            elif kind in ("scheduler", "migrate"):
                summary[kind] = parts[1] == "yes"
            elif kind in ("start", "install", "build", "node_version", "python_requirements", "health_path"):
                summary[kind] = parts[1]
            elif kind == "health_timeout":
                summary[kind] = int(parts[1])
            elif kind == "shared":
                summary.setdefault("shared", []).append(parts[1])
        return summary
    return None


def certificate(domain: str) -> dict | None:
    """Certificate nginx serves for the site: names, issuer, expiry (no key material)."""
    conf = NGINX / f"{domain}.conf"
    try:
        match = re.search(r"^\s*ssl_certificate\s+([^;\s]+);", conf.read_text(), re.M)
    except OSError:
        return None
    if not match:
        return None
    path = match.group(1)
    try:
        out = subprocess.run(["openssl", "x509", "-in", path, "-noout", "-enddate", "-issuer", "-ext", "subjectAltName",
                              "-nameopt", "multiline"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    end = re.search(r"^notAfter=(.+)$", out, re.M)
    if not end:
        return {"path": path, "valid": False}
    not_after = datetime.strptime(end.group(1).strip(), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    issuer = {k.strip(): v.strip() for k, v in re.findall(r"^\s+(commonName|organizationName)\s*=\s*(.+)$", out, re.M)}
    names = re.findall(r"DNS:([^,\s]+)", out)
    return {
        "path": path,
        "valid": True,
        "names": names,
        "issuer": issuer.get("organizationName") or issuer.get("commonName"),
        "not_after": not_after.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "days_left": (not_after - datetime.now(timezone.utc)).days,
        "auto_renew": (Path("/etc/letsencrypt/renewal") / f"{domain}.conf").is_file(),
    }


def backups(domain: str, project: str) -> dict:
    """Data backups of the site: schedule and the backup directories it keeps."""
    cron = Path("/etc/cron.d") / f"simai-backup-{project}"
    schedule, dests = None, {os.environ.get("SIMAI_BACKUP_DEST", "/var/backups/simai")}
    try:
        line = next(l for l in cron.read_text().splitlines() if l and not l.startswith("#"))
        fields = line.split()
        opts = dict(zip(fields[::1], fields[1::1]))
        schedule = {"time": f"{int(fields[1]):02d}:{int(fields[0]):02d}", "keep": opts.get("--keep"), "dest": opts.get("--dest")}
        if schedule["dest"]:
            dests.add(schedule["dest"])
    except (OSError, StopIteration, ValueError, IndexError):
        pass
    items = []
    for dest in sorted(dests):
        base = Path(dest) / domain
        if not base.is_dir():
            continue
        for d in sorted(base.iterdir(), reverse=True):
            if not (d.is_dir() and re.match(r"^\d{8}-\d{6}$", d.name)):
                continue
            files = [f for f in d.iterdir() if f.is_file()]
            items.append({
                "path": str(d),
                "created_at": datetime.strptime(d.name, "%Y%m%d-%H%M%S").strftime("%Y-%m-%dT%H:%M:%S"),
                "size_bytes": sum(f.stat().st_size for f in files),
                "parts": sorted(n for n in ("db", "files", "config") if any(f.name.startswith(n + ".") for f in files)),
                "checksums": (d / "SHA256SUMS").is_file(),
                "encrypted": any(f.name.endswith(".age") for f in files),
            })
    return {"schedule": schedule, "items": items}


def describe_site(domain: str, detailed: bool) -> dict:
    meta = metadata(domain)
    project = meta.get("project") or domain.replace(".", "-")
    root = Path(meta.get("root", ""))
    runs_as = None
    reg = STATE / "site-users" / project
    if reg.is_file():
        runs_as = reg.read_text().strip()
    owner = runs_as if runs_as and (STATE / "owners" / runs_as).is_file() else None
    db = kv_file(STATE / "sites" / domain / "db.env", DB_KEYS)
    if db and "DB_ENGINE" not in db:
        db["DB_ENGINE"] = "mysql"
    deploy = kv_file(STATE / "sites" / domain / "deploy.env")
    layout = "releases" if (root / "current").is_symlink() else "in-place"
    workers = []
    for unit in sorted(UNITS.glob(f"laravel-queue-{project}*.service")):
        if unit.name == f"laravel-queue-{project}.service" or unit.name.startswith(f"laravel-queue-{project}-"):
            workers.append({"unit": unit.name, "state": active(unit.name)})
    service_port = kv_file(STATE / "sites" / domain / "service.env").get("APP_PORT")
    service = None
    if service_port:
        unit = f"simai-app-{project}.service"
        service = {"unit": unit, "port": int(service_port), "listen": f"127.0.0.1:{service_port}",
                   "state": active(unit) if (UNITS / unit).is_file() else "not deployed"}
    info = {
        "domain": domain,
        "profile": meta.get("profile"),
        "php": meta.get("php"),
        "root": str(root),
        "public_dir": meta.get("public-dir"),
        "ssl": meta.get("ssl"),
        "certificate": certificate(domain),
        "frame_policy": meta.get("frame-policy", "same-origin"),
        "runs_as": runs_as or "simai (shared, not isolated)",
        "owner": owner,
        "database": {"engine": db.get("DB_ENGINE"), "name": db.get("DB_NAME"), "user": db.get("DB_USER"),
                     "host": db.get("DB_HOST"), "port": db.get("DB_PORT")} if db else None,
        "layout": layout,
        "release": {"current": deploy.get("CURRENT"), "previous": deploy.get("PREVIOUS"),
                    "deployed_at": deploy.get("DEPLOYED_AT"), "source": deploy.get("SOURCE")} if deploy else None,
        "workers": workers,
        "service": service,
        "scheduler": (Path("/etc/cron.d") / project).is_file(),
        "backup_schedule": (Path("/etc/cron.d") / f"simai-backup-{project}").is_file(),
        "adopted": kv_file(STATE / "sites" / domain / "app.env").get("ADOPTED_AT"),
    }
    if detailed:
        cli = "simai-admin.sh"
        info["manifest"] = manifest_summary(root)
        info["backups"] = backups(domain, project)
        info["logs"] = {
            "nginx_error": f"/var/log/nginx/{project}.error.log",
            "php_fpm": f"/var/log/php{meta.get('php')}-fpm-{project}.log",
            "app": str(root / "storage" / "logs"),
            "workers": [f"journalctl -u {w['unit']}" for w in workers],
        }
        if service:
            info["logs"]["service"] = f"journalctl -u {service['unit']}"
            info["logs"].pop("php_fpm", None)
        info["how_to"] = {
            "inspect": f"{cli} site doctor --domain {domain}",
            "deploy": f"{cli} site deploy --domain {domain} --git <url> --ref <tag> --confirm yes",
            "deploy_archive": f"{cli} site deploy --domain {domain} --archive <file.tar.gz> --sha256 <sum> --confirm yes",
            "rollback": f"{cli} site deploy-rollback --domain {domain} --confirm yes",
            "reconcile_requirements": f"{cli} site adopt --domain {domain} --confirm yes",
            "backup": f"{cli} backup data --domain {domain} --confirm yes",
            "verify_backup": f"{cli} backup data-verify --path <backup-dir> --restore-test yes --confirm yes",
            "run_artisan_as_site_user": f"sudo -u {runs_as or 'simai'} -H php{meta.get('php')} {root}/{'current/' if layout == 'releases' else ''}artisan <command>",
        }
        if service:
            info["how_to"].pop("run_artisan_as_site_user", None)
            info["how_to"].pop("reconcile_requirements", None)
            info["how_to"]["service_status"] = f"systemctl status {service['unit']}"
            info["how_to"]["service_logs"] = f"journalctl -u {service['unit']} -n 100"
            info["how_to"]["service_restart"] = f"{cli} site service-restart --domain {domain} --confirm yes"
        info["rules"] = [
            "Commands that change state print a plan unless --confirm yes is given; read the plan first.",
            "Do not edit nginx, PHP-FPM, cron or systemd files by hand; use simai-admin.sh so metadata stays consistent.",
            "Application secrets live in the site .env and /etc/simai-env/sites/<domain>/db.env; never print them.",
        ]
    return info


def describe_host(root: str) -> dict:
    os_release = kv_file(Path("/etc/os-release"))
    php_versions = sorted(p.parent.name for p in Path("/etc/php").glob("*/fpm")) if Path("/etc/php").is_dir() else []
    owners = []
    registry = STATE / "site-users"
    for owner_file in sorted((STATE / "owners").glob("*")) if (STATE / "owners").is_dir() else []:
        projects = [f.name for f in registry.glob("*") if f.is_file() and f.read_text().strip() == owner_file.name] if registry.is_dir() else []
        owners.append({"name": owner_file.name, "projects": sorted(projects)})
    version = Path(root, "VERSION").read_text().strip() if Path(root, "VERSION").is_file() else None
    services = {name: active(unit) for name, unit in (
        ("nginx", "nginx"), ("mysql", "mysql"), ("postgresql", "postgresql"),
        ("redis", "redis-server"), ("cron", "cron"))}
    services.update({f"php{v}-fpm": active(f"php{v}-fpm") for v in php_versions})
    return {
        "schema": "simai-host/1",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "simai_env": {"version": version, "root": root, "cli": f"{root}/simai-admin.sh"},
        "os": {"id": os_release.get("ID", "").strip('"'), "version": os_release.get("VERSION_ID", "").strip('"')},
        "services": services,
        "php_versions": php_versions,
        "isolation": {"new_sites": "own user unless SIMAI_SITE_ISOLATION=no", "owners": owners},
        "sites": [describe_site(d, False) for d in site_domains()],
        "next": {
            "site_details": "simai-admin.sh site describe --domain <domain>",
            "all_commands": "simai-admin.sh self commands",
            "agent_guide": f"{root}/AGENTS.md",
        },
    }


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: host_describe.py <simai-root> host|site [domain]", file=sys.stderr)
        return 2
    root, mode = sys.argv[1], sys.argv[2]
    if mode == "host":
        data = describe_host(root)
    elif mode == "site" and len(sys.argv) == 4 and re.fullmatch(r"[a-z0-9.-]+", sys.argv[3]):
        if not (NGINX / f"{sys.argv[3]}.conf").is_file():
            print(f"site {sys.argv[3]} is not managed here", file=sys.stderr)
            return 1
        data = describe_site(sys.argv[3], True)
        data["schema"] = "simai-site/1"
    else:
        print("invalid arguments", file=sys.stderr)
        return 2
    json.dump(data, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
