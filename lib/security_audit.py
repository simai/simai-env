#!/usr/bin/env python3
"""Security center: a passive check of the server and its sites.

Usage: security_audit.py status OUTPUT          (live local checks + the last online scan)
       security_audit.py refresh [online|auto]  (writes the report; online: query vulnerability
                                                 databases now, auto: when the last scan is a day old)

Local checks look at the system only (updates, SSH, firewall, Fail2ban,
services open to the network, PHP support, HTTPS, certificates, backups,
the panel). The online scan sends the names and versions of the packages in
each site's composer.lock and package-lock.json to OSV (api.osv.dev) and asks
api.wordpress.org for the current WordPress version; nothing else leaves the
server. It can be turned off with SIMAI_SECURITY_ONLINE=no in
/etc/simai-env.conf.

Every check: {id, area, title, status: ok|warn|risk|unknown, severity:
low|medium|high|critical, detail, domain, fix: {command, args} | null, how}.
`fix` is a panel gateway command that resolves it in one click; `how` says
what to do when there is none. The score starts at 100 and loses points for
every open problem by its severity.

Files inside site directories are written by the applications and may be
attacker-controlled: lock files are parsed as data with size limits, and only
package names and versions that look valid are used.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import host_describe  # noqa: E402
import software_state  # noqa: E402

STATE_DIR = Path(os.environ.get("SIMAI_SECURITY_STATE", "/var/lib/simai-env/security"))
REPORT = STATE_DIR / "report.json"
ONLINE = STATE_DIR / "online.json"
VULN_CACHE = STATE_DIR / "osv-vulns.json"
STORAGES = Path(os.environ.get("SIMAI_BACKUP_STORAGE_DIR", "/etc/simai-env/backup-storages"))
PANEL_STATE = Path(os.environ.get("SIMAI_PANEL_STATE", "/etc/simai-env/panel.env"))
OSV = os.environ.get("SIMAI_OSV_URL", "https://api.osv.dev")
WP_API = os.environ.get("SIMAI_WP_VERSION_URL", "https://api.wordpress.org/core/version-check/1.7/")
MAX_LOCK = 20 * 1048576
WEIGHT = {"critical": 30, "high": 15, "medium": 7, "low": 2}
# Upstream security support of PHP branches (php.net/supported-versions).
PHP_EOL = {"5.6": "2018-12-31", "7.0": "2019-01-10", "7.1": "2019-12-01", "7.2": "2020-11-30",
           "7.3": "2021-12-06", "7.4": "2022-11-28", "8.0": "2023-11-26", "8.1": "2025-12-31",
           "8.2": "2026-12-31", "8.3": "2027-12-31", "8.4": "2028-12-31", "8.5": "2029-12-31"}
NATIVE_PHP = {"jammy": "8.1", "noble": "8.3", "resolute": "8.5"}  # patched by Ubuntu itself
EXPOSED = {3306: "MySQL", 5432: "PostgreSQL", 6379: "Redis", 11211: "Memcached", 27017: "MongoDB",
           9000: "PHP-FPM", 9200: "Elasticsearch", 5672: "RabbitMQ"}
NAME = re.compile(r"^[A-Za-z0-9@][A-Za-z0-9._/@-]{0,213}$")
VERSION = re.compile(r"^v?[0-9][0-9A-Za-z.+-]{0,63}$")


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sh(*cmd: str, timeout: int = 20) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


def load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def save(path: Path, data) -> None:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def check(cid, area, title, status, severity, detail, domain=None, fix=None, how=None) -> dict:
    return {"id": cid if not domain else f"{cid}:{domain}", "check": cid, "area": area, "title": title,
            "status": status, "severity": severity, "detail": detail, "domain": domain, "fix": fix, "how": how}


def fix(command: str, **args) -> dict:
    return {"command": command, "args": args}


def codename() -> str:
    for line in Path("/etc/os-release").read_text().splitlines() if Path("/etc/os-release").is_file() else []:
        if line.startswith("VERSION_CODENAME="):
            return line.split("=", 1)[1].strip('"')
    return ""


# ---------------------------------------------------------------- server

def check_updates() -> list[dict]:
    out = []
    try:
        rows, _ = software_state.upgradable()
    except Exception:  # noqa: BLE001 - apt may be busy
        rows = None
    if rows is None:
        out.append(check("security_updates", "updates", "Security updates", "unknown", "high",
                         "the package list could not be read (apt is busy?)"))
    else:
        sec = sorted(r["name"] for r in rows if r["security"])
        if sec:
            out.append(check("security_updates", "updates", "Security updates", "risk",
                             "critical" if len(sec) >= 10 else "high",
                             f"{len(sec)} packages have security fixes waiting: {', '.join(sec[:12])}"
                             + ("…" if len(sec) > 12 else ""), fix=fix("software:update", **{"security-only": "yes"}),
                             how="Install the updates: they close known vulnerabilities (CVE)."))
        else:
            out.append(check("security_updates", "updates", "Security updates", "ok", "high",
                             "all security fixes are installed"))
    auto = Path("/etc/apt/apt.conf.d/20auto-upgrades")
    enabled = auto.is_file() and re.search(r'Unattended-Upgrade\s+"1"', auto.read_text()) \
        and Path("/usr/bin/unattended-upgrade").exists()
    out.append(check("auto_updates", "updates", "Automatic security updates", "ok" if enabled else "warn", "high",
                     "security fixes are installed every day automatically" if enabled
                     else "security fixes are installed only by hand",
                     fix=None if enabled else fix("security:fix", check="auto_updates"),
                     how=None if enabled else "Turn on unattended upgrades so fixes arrive while nobody looks."))
    if Path("/var/run/reboot-required").exists():
        pkgs = Path("/var/run/reboot-required.pkgs")
        names = sorted(set(pkgs.read_text().split())) if pkgs.is_file() else []
        out.append(check("reboot_required", "updates", "Restart after updates", "warn", "medium",
                         "a restart is needed to finish updates" + (f" ({', '.join(names[:6])})" if names else ""),
                         how="Restart the server at a quiet time; the new kernel or libraries start working after it."))
    else:
        out.append(check("reboot_required", "updates", "Restart after updates", "ok", "medium", "no restart pending"))
    return out


def check_ssh() -> list[dict]:
    rc, out = sh("sshd", "-T")
    if rc != 0 or not out:
        return [check("ssh_password", "access", "SSH login by password", "unknown", "high", "sshd settings unreadable")]
    conf = dict(line.split(" ", 1) for line in out.splitlines() if " " in line)
    keys = any(Path(p).is_file() and Path(p).stat().st_size > 0
               for p in ["/root/.ssh/authorized_keys", *map(str, Path("/home").glob("*/.ssh/authorized_keys"))])
    res = []
    password = conf.get("passwordauthentication", "yes") == "yes" or conf.get("kbdinteractiveauthentication") == "yes"
    res.append(check("ssh_password", "access", "SSH login by password",
                     "warn" if password else "ok", "high",
                     "passwords can be guessed: anyone may try them" if password else "only keys are accepted",
                     fix=fix("security:fix", check="ssh_password") if password and keys else None,
                     how=None if not password else ("Allow SSH keys only." if keys else
                                                    "Add your SSH key first (owner add-key), then allow keys only.")))
    root = conf.get("permitrootlogin", "prohibit-password")
    res.append(check("ssh_root", "access", "SSH login as root", "warn" if root == "yes" else "ok", "medium",
                     "root may log in with a password" if root == "yes" else f"root: {root}",
                     fix=fix("security:fix", check="ssh_password") if root == "yes" and keys else None,
                     how="Let root log in with a key only." if root == "yes" else None))
    return res


def check_firewall() -> list[dict]:
    rc, out = sh("ufw", "status")
    active = rc == 0 and "Status: active" in out
    res = [check("firewall", "network", "Firewall", "ok" if active else "risk", "high",
                 "only allowed ports are open" if active else "every port of the server is reachable",
                 fix=None if active else fix("self:firewall-ensure"),
                 how=None if active else "Turn on the firewall: it keeps SSH, HTTP and HTTPS open and closes the rest.")]
    f2b = sh("systemctl", "is-active", "fail2ban")[1].strip() == "active"
    res.append(check("fail2ban", "network", "Blocking of password guessing", "ok" if f2b else "warn", "medium",
                     "Fail2ban blocks addresses that guess passwords" if f2b else "nobody blocks password guessing",
                     fix=None if f2b else fix("security:fix", check="fail2ban"),
                     how=None if f2b else "Install Fail2ban: it bans addresses after failed SSH logins."))
    rc, out = sh("ss", "-ltnH")
    exposed = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        addr, _, port = parts[3].rpartition(":")
        if port.isdigit() and int(port) in EXPOSED and addr in ("0.0.0.0", "*", "[::]", "::"):
            exposed[int(port)] = EXPOSED[int(port)]
    if exposed:
        names = ", ".join(f"{n} ({p})" for p, n in sorted(exposed.items()))
        res.append(check("exposed_services", "network", "Services open to the network", "warn" if active else "risk",
                         "medium" if active else "high",
                         f"listen on all addresses: {names}" + ("; the firewall closes them" if active else ""),
                         how="Bind them to 127.0.0.1 unless another server must reach them; "
                             "for a database use db network access with a list of addresses."))
    else:
        res.append(check("exposed_services", "network", "Services open to the network", "ok", "high",
                         "databases and caches listen on this server only"))
    return res


def check_panel(access_file: str) -> list[dict]:
    domain = None
    if PANEL_STATE.is_file():
        vals = [l.split("=", 1)[1] for l in PANEL_STATE.read_text().splitlines() if l.startswith("PANEL_DOMAIN=")]
        domain = vals[-1] if vals and vals[-1] else None
    if not domain:
        return []
    allowed = []
    try:
        allowed = [l.split()[1].rstrip(";") for l in Path(access_file).read_text().splitlines()
                   if l.startswith("allow ") and "# local" not in l]
    except (OSError, IndexError):
        pass
    return [check("panel_access", "access", "Who can open the panel", "ok" if allowed else "warn", "low",
                  f"only {', '.join(allowed[:5])}" if allowed else "the panel login page is open to everybody",
                  how=None if allowed else "If you work from fixed addresses, let only them open the panel (panel access).")]


# ---------------------------------------------------------------- sites

def site_rows() -> list[dict]:
    status = host_describe.site_status()
    rows = []
    for d in host_describe.site_domains():
        try:
            rows.append(host_describe.describe_site(d, False, status))
        except Exception:  # noqa: BLE001 - one broken site must not hide the others
            continue
    return rows


def check_sites(sites: list[dict]) -> list[dict]:
    res = []
    native = NATIVE_PHP.get(codename())
    today = date.today()
    storages = list(STORAGES.glob("*.env")) if STORAGES.is_dir() else []
    data_sites = [s for s in sites if s.get("profile") not in ("alias", "redirect", "proxy")]
    for s in sites:
        d = s["domain"]
        php = s.get("php")
        if php and php not in ("none", "") and php in PHP_EOL and php != native:
            eol = date.fromisoformat(PHP_EOL[php])
            if eol < today:
                res.append(check("php_eol", "sites", "PHP without security fixes", "risk", "high",
                                 f"PHP {php} gets no security fixes since {PHP_EOL[php]}", d,
                                 how="Move the site to a supported PHP version (php switch) after a test."))
            elif eol < today + timedelta(days=120):
                res.append(check("php_eol", "sites", "PHP support ends soon", "warn", "low",
                                 f"PHP {php} gets security fixes until {PHP_EOL[php]}", d,
                                 how="Plan the move to a newer PHP version."))
        if s.get("profile") == "alias":
            continue
        if (s.get("ssl") or "none") == "none":
            res.append(check("https", "sites", "HTTPS", "warn", "medium", "the site opens without encryption", d,
                             fix=fix("ssl:letsencrypt", domain=d),
                             how="Issue a free Let's Encrypt certificate (the domain must point to this server)."))
        cert = s.get("certificate") or {}
        days = cert.get("days_left")
        if isinstance(days, int) and days < 14:
            res.append(check("certificate", "sites", "Certificate expires", "risk" if days < 3 else "warn", "high",
                             f"the certificate expires in {days} days", d, fix=fix("ssl:renew", domain=d),
                             how="Renew the certificate; check that the domain still points to this server."))
    for s in data_sites:
        d = s["domain"]
        if not s.get("backup_schedule"):
            res.append(check("backup_schedule", "backups", "Daily backup", "warn", "high",
                             "the site has no daily backup", d,
                             fix=fix("backup:data-schedule", domain=d, enabled="yes"),
                             how="Turn on the daily backup."))
            continue
        last = s.get("last_offsite")
        if storages and last and last.get("ok") is False:
            res.append(check("backup_offsite", "backups", "Copy outside the server", "risk", "high",
                             f"the last upload to {last.get('storage')} failed", d,
                             fix=fix("backup:storage-test", name=last.get("storage") or ""),
                             how="Check the storage keys and the bucket."))
        verify = s.get("last_verify") or {}
        at = verify.get("at")
        fresh = False
        if at and verify.get("ok"):
            try:
                fresh = datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) \
                    > datetime.now(timezone.utc) - timedelta(days=31)
            except ValueError:
                pass
        if not fresh:
            res.append(check("backup_verify", "backups", "Backup checked", "warn", "low",
                             "no backup was checked in the last month" if not at or verify.get("ok")
                             else "the last check of a backup failed", d,
                             fix=fix("backup:data-schedule", domain=d, enabled="yes", verify="yes"),
                             how="Let every scheduled backup be checked with a test restore."))
    if data_sites:
        res.append(check("backup_storage", "backups", "Copies outside the server",
                         "ok" if storages else "warn", "medium",
                         f"backups go to {len(storages)} storage(s)" if storages
                         else "backups stay on this server only: a lost server loses them too",
                         how=None if storages else "Add an S3 storage: every backup is then copied there."))
    return res


# ---------------------------------------------------------------- online scan

def site_root(s: dict) -> Path:
    root = Path(s.get("root") or "/nonexistent")
    return root / "current" if (root / "current").is_dir() else root


def read_lock(path: Path):
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_LOCK:
            return None
        return json.loads(path.read_text(errors="replace"))
    except (OSError, ValueError):
        return None


def packages(root: Path) -> list[tuple[str, str, str]]:
    found = []
    lock = read_lock(root / "composer.lock")
    if isinstance(lock, dict):
        for key in ("packages", "packages-dev"):
            for p in lock.get(key) or []:
                if isinstance(p, dict):
                    found.append(("Packagist", str(p.get("name", "")), str(p.get("version", "")).lstrip("v")))
    lock = read_lock(root / "package-lock.json")
    if isinstance(lock, dict):
        if isinstance(lock.get("packages"), dict):
            for path, p in lock["packages"].items():
                if path and isinstance(p, dict) and "node_modules/" in path:
                    found.append(("npm", path.rsplit("node_modules/", 1)[1], str(p.get("version", ""))))
        else:
            stack = [lock.get("dependencies") or {}]
            while stack and len(found) < 20000:
                deps = stack.pop()
                for name, p in deps.items() if isinstance(deps, dict) else []:
                    if isinstance(p, dict):
                        found.append(("npm", name, str(p.get("version", ""))))
                        stack.append(p.get("dependencies") or {})
    return sorted({f for f in found if NAME.match(f[1]) and VERSION.match(f[2])})[:5000]


def post(url: str, body: dict, timeout: int = 30):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "simai-env"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - fixed https endpoints
        return json.loads(r.read(16 * 1048576))


def get(url: str, timeout: int = 20):
    req = urllib.request.Request(url, headers={"User-Agent": "simai-env"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310
        return json.loads(r.read(4 * 1048576))


def severity_of(v: dict) -> str:
    sev = str((v.get("database_specific") or {}).get("severity") or "").lower()
    if sev in ("critical", "high", "medium", "moderate", "low"):
        return "medium" if sev == "moderate" else sev
    for s in v.get("severity") or []:
        m = re.search(r"/AV:N/", str(s.get("score", "")))
        if m:
            return "high"
    return "medium"


def fixed_in(v: dict, name: str) -> str | None:
    for a in v.get("affected") or []:
        if (a.get("package") or {}).get("name") != name:
            continue
        for r in a.get("ranges") or []:
            for e in r.get("events") or []:
                if e.get("fixed"):
                    return str(e["fixed"])
    return None


def online_scan(sites: list[dict]) -> dict:
    result = {"checked_at": now(), "error": None, "sites": {}}
    queries, owners = [], []
    for s in sites:
        if s.get("profile") in ("alias", "redirect", "proxy", "static"):
            continue
        pk = packages(site_root(s))
        result["sites"][s["domain"]] = {"packages": len(pk), "vulnerabilities": [], "wordpress": None}
        for eco, name, ver in pk:
            queries.append({"package": {"ecosystem": eco, "name": name}, "version": ver})
            owners.append((s["domain"], eco, name, ver))
    cache = load(VULN_CACHE, {})
    try:
        hits = []
        for i in range(0, len(queries), 500):
            answer = post(f"{OSV}/v1/querybatch", {"queries": queries[i:i + 500]})
            hits += answer.get("results") or []
        for (domain, eco, name, ver), hit in zip(owners, hits):
            for v in (hit or {}).get("vulns") or []:
                vid = str(v.get("id", ""))
                if not re.match(r"^[A-Za-z0-9._:-]{3,64}$", vid):
                    continue
                if vid not in cache or cache[vid].get("modified") != v.get("modified"):
                    full = get(f"{OSV}/v1/vulns/{vid}")
                    cache[vid] = {"modified": v.get("modified"), "summary": str(full.get("summary") or "")[:200],
                                  "severity": severity_of(full), "aliases": (full.get("aliases") or [])[:5],
                                  "fixed": {n: fixed_in(full, n) for n in {name}}}
                c = cache[vid]
                result["sites"][domain]["vulnerabilities"].append({
                    "ecosystem": eco, "package": name, "version": ver, "id": vid, "aliases": c["aliases"],
                    "severity": c["severity"], "summary": c["summary"], "fixed": (c.get("fixed") or {}).get(name)})
        save(VULN_CACHE, cache)
    except Exception as e:  # noqa: BLE001 - offline, rate limited, bad answer
        result["error"] = f"vulnerability database unreachable: {type(e).__name__}"
    latest = None
    for s in sites:
        if s.get("profile") != "wordpress":
            continue
        vfile = site_root(s) / "wp-includes" / "version.php"
        try:
            m = re.search(r"\$wp_version\s*=\s*'([0-9.]{1,16})'", vfile.read_text(errors="replace")[:20000])
        except OSError:
            m = None
        if not m:
            continue
        if latest is None:
            try:
                latest = str(get(WP_API)["offers"][0]["current"])
            except Exception:  # noqa: BLE001
                latest = ""
        result["sites"].setdefault(s["domain"], {"packages": 0, "vulnerabilities": []})["wordpress"] = {
            "version": m.group(1), "latest": latest or None}
    return result


def check_online(online: dict) -> list[dict]:
    res = []
    if not online:
        return [check("vulnerability_scan", "sites", "Vulnerable site components", "unknown", "high",
                      "not checked yet", fix=fix("security:scan"),
                      how="Run a scan; it then runs every day by itself.")]
    if online.get("error"):
        res.append(check("vulnerability_scan", "sites", "Vulnerable site components", "unknown", "high",
                         online["error"], fix=fix("security:scan"), how="Check that the server reaches api.osv.dev."))
    order = ["low", "medium", "high", "critical"]
    for domain, s in sorted((online.get("sites") or {}).items()):
        vulns = s.get("vulnerabilities") or []
        if vulns:
            worst = max((v["severity"] for v in vulns), key=order.index)
            pk = sorted({f"{v['package']} {v['version']}" for v in vulns})
            res.append(check("site_components", "sites", "Vulnerable site components",
                             "risk" if worst in ("critical", "high") else "warn", worst,
                             f"{len(vulns)} known vulnerabilities in {len(pk)} packages: {', '.join(pk[:6])}"
                             + ("…" if len(pk) > 6 else ""), domain,
                             how="Update these packages (composer update / npm update) in the project and deploy."))
        elif s.get("packages"):
            res.append(check("site_components", "sites", "Vulnerable site components", "ok", "high",
                             f"{s['packages']} packages, no known vulnerabilities", domain))
        wp = s.get("wordpress")
        if wp and wp.get("latest") and wp["version"] != wp["latest"]:
            res.append(check("wordpress_core", "sites", "WordPress version", "warn", "high",
                             f"WordPress {wp['version']}, current {wp['latest']}", domain,
                             how="Update WordPress in its admin (Dashboard → Updates) after a backup."))
    return res


# ---------------------------------------------------------------- report

def report(access_file: str, online_mode: str = "") -> dict:
    sites = site_rows()
    online = load(ONLINE, {})
    enabled = os.environ.get("SIMAI_SECURITY_ONLINE", "yes") != "no"
    stale = True
    try:
        stale = datetime.strptime(online["checked_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) \
            < datetime.now(timezone.utc) - timedelta(hours=23)
    except (KeyError, TypeError, ValueError):
        pass
    if enabled and (online_mode == "online" or (online_mode == "auto" and stale)):
        online = online_scan(sites)
        save(ONLINE, online)
    checks = check_updates() + check_ssh() + check_firewall() + check_panel(access_file) + check_sites(sites)
    checks += check_online(online) if enabled else []
    lost = sum(WEIGHT[c["severity"]] if c["status"] == "risk" else WEIGHT[c["severity"]] // 2 + 1
               for c in checks if c["status"] in ("risk", "warn"))
    score = max(0, 100 - lost)
    problems = [c for c in checks if c["status"] in ("risk", "warn")]
    order = {"critical": 0, "high": 1, "medium": 2, "low": 3}
    problems.sort(key=lambda c: (c["status"] != "risk", order[c["severity"]]))
    return {"schema": "simai-security/1", "checked_at": now(), "score": score,
            "grade": "good" if score >= 90 else "attention" if score >= 70 else "risk",
            "summary": {"risk": sum(c["status"] == "risk" for c in checks),
                        "warn": sum(c["status"] == "warn" for c in checks),
                        "ok": sum(c["status"] == "ok" for c in checks),
                        "unknown": sum(c["status"] == "unknown" for c in checks)},
            "recommendations": [c["id"] for c in problems],
            "online": {"enabled": enabled, "checked_at": online.get("checked_at"), "error": online.get("error")},
            "checks": checks,
            "vulnerabilities": {d: s.get("vulnerabilities") or [] for d, s in (online.get("sites") or {}).items()
                                if s.get("vulnerabilities")}}


def human(r: dict) -> None:
    mark = {"risk": "!!", "warn": " !", "ok": "ok", "unknown": " ?"}
    print(f"Security score {r['score']}/100 ({r['grade']}), checked {r['checked_at']}")
    by_id = {c["id"]: c for c in r["checks"]}
    for cid in r["recommendations"]:
        c = by_id[cid]
        print(f"  {mark[c['status']]} {c['title']}{' · ' + c['domain'] if c['domain'] else ''}: {c['detail']}")
        if c["fix"]:
            cmd = c["fix"]["command"].replace(":", " ", 1)
            args = " ".join(f"--{k} {v}" for k, v in c["fix"]["args"].items())
            print(f"       fix: simai-admin.sh {cmd} {args} --confirm yes".replace("  ", " "))
        elif c["how"]:
            print(f"       {c['how']}")
    print(f"  {r['summary']['ok']} checks are fine"
          + (f", {r['summary']['unknown']} could not be checked" if r["summary"]["unknown"] else ""))


def main(argv: list[str]) -> int:
    mode = argv[0] if argv else "status"
    access_file = os.environ.get("SIMAI_PANEL_ACCESS_FILE", "")
    if mode == "status":
        r = report(access_file)
        if (argv[1:2] or ["human"])[0] == "json":
            print(json.dumps(r, ensure_ascii=False))
        else:
            human(r)
        return 0
    if mode == "refresh":
        r = report(access_file, (argv[1:2] or [""])[0])
        save(REPORT, r)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
