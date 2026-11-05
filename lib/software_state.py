#!/usr/bin/env python3
"""Server software for `software list`: the components simai-env manages
(web server, databases, Redis, Node.js, tools) with their installed and
candidate versions, and the package updates of the whole system. Reads only;
the apt index is as fresh as the last `apt-get update` (`index_age_seconds`).

Usage: software_state.py OUTPUT          (OUTPUT json|human; simai-software/1)
       software_state.py entry KEY       (one catalogue entry, with what removal takes)
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

SITES = Path("/etc/simai-env/sites")

# The catalogue: key, title, purpose, group, packages detected (the first
# installed one counts), packages installed/removed, service, PHP extension
# installed with it for every PHP version, paths kept on removal, how it is
# installed ("apt", a special handler, or None when simai-env owns it).
CATALOG = [
    dict(key="nginx", title="nginx", group="web", detect=["nginx"], service="nginx", how=None,
         purpose="Web server in front of every site: HTTPS, access rules, static files"),
    dict(key="apache", title="Apache", group="web", detect=["apache2"], packages=["apache2"], service="apache2",
         how="apache", keeps=["/etc/apache2"],
         purpose="Serves PHP sites that rely on .htaccess, behind nginx (site apache)"),
    dict(key="certbot", title="Certbot", group="security", detect=["certbot"], packages=["certbot"], how="apt",
         keeps=["/etc/letsencrypt"], purpose="Gets and renews free Let's Encrypt certificates"),
    dict(key="fail2ban", title="Fail2ban", group="security", detect=["fail2ban"], packages=["fail2ban"],
         service="fail2ban", how="apt", keeps=["/etc/fail2ban"],
         purpose="Bans addresses that keep failing to sign in over SSH"),
    dict(key="mysql", title="MySQL", group="databases",
         detect=["percona-server-server", "mysql-server", "mariadb-server"], service="mysql", how=None,
         purpose="Database server for most sites"),
    dict(key="postgresql", title="PostgreSQL", group="databases", detect=["postgresql"], service="postgresql",
         how="postgresql", keeps=["/var/lib/postgresql", "/etc/postgresql"],
         purpose="Database server for sites that choose PostgreSQL"),
    dict(key="redis", title="Redis", group="cache", detect=["redis-server"], packages=["redis-server"],
         service="redis-server", php_ext="redis", how="apt", keeps=["/var/lib/redis", "/etc/redis"],
         purpose="In-memory store for cache, sessions and queues"),
    dict(key="memcached", title="Memcached", group="cache", detect=["memcached"], packages=["memcached"],
         service="memcached", php_ext="memcached", how="apt", keeps=["/etc/memcached.conf"],
         purpose="In-memory cache for applications that use it"),
    dict(key="php", title="PHP", group="languages", detect=[], how=None,
         purpose="PHP versions for sites; managed in the PHP section"),
    dict(key="node", title="Node.js", group="languages", detect=["nodejs"], packages=["nodejs"], how="node",
         purpose="JavaScript runtime for node sites and front-end builds"),
    dict(key="composer", title="Composer", group="languages", detect=[], how=None,
         purpose="PHP dependency manager used by deploys"),
    dict(key="git", title="Git", group="tools", detect=["git"], how=None,
         purpose="Fetches site code for deploys"),
    dict(key="imagemagick", title="ImageMagick", group="tools", detect=["imagemagick"], packages=["imagemagick"],
         php_ext="imagick", how="apt", purpose="Image processing for applications (PHP imagick)"),
    dict(key="jpegoptim", title="jpegoptim", group="tools", detect=["jpegoptim"], packages=["jpegoptim"], how="apt",
         purpose="Makes JPEG images smaller without visible loss"),
    dict(key="optipng", title="OptiPNG", group="tools", detect=["optipng"], packages=["optipng"], how="apt",
         purpose="Makes PNG images smaller without loss"),
    dict(key="ffmpeg", title="FFmpeg", group="tools", detect=["ffmpeg"], packages=["ffmpeg"], how="apt",
         purpose="Converts and processes video and audio"),
    dict(key="supervisor", title="Supervisor", group="tools", detect=["supervisor"], packages=["supervisor"],
         service="supervisor", how="apt", keeps=["/etc/supervisor"],
         purpose="Keeps long-running processes alive (simai-env uses systemd for its own)"),
]
KEYS = [c["key"] for c in CATALOG]
# A removal that would also take one of these away is refused.
PROTECTED = re.compile(r"^(nginx.*|php[0-9.]*(-.*)?|percona-.*|mysql-.*|mariadb-.*|postgresql.*|openssh-.*|"
                       r"git|certbot|python3(-.*)?|systemd.*|sudo|curl|cron|ca-certificates|apache2.*|redis.*|"
                       r"nodejs|libc6|bash|coreutils|dpkg|apt)$")


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


def php_versions():
    return sorted({p.name for p in Path("/etc/php").glob("[0-9]*") if (p / "fpm").is_dir()}) \
        if Path("/etc/php").is_dir() else []


def sites_by(key):
    """Domains that need a program, from their metadata (never the site .env)."""
    if key == "node":
        return node_sites()
    out = []
    for d in sorted(SITES.glob("*")) if SITES.is_dir() else []:
        def kv(name, field):
            try:
                for line in (d / name).read_text(errors="replace").splitlines():
                    if line.startswith(field + "="):
                        return line.split("=", 1)[1].strip()
            except OSError:
                pass
            return None
        if key == "apache" and kv("web.env", "BACKEND") == "apache":
            out.append(d.name)
        elif key == "postgresql" and kv("db.env", "DB_ENGINE") == "pgsql":
            out.append(d.name)
        elif key == "mysql" and (d / "db.env").is_file() and (kv("db.env", "DB_ENGINE") or "mysql") == "mysql":
            out.append(d.name)
    return out


def certificates():
    live = Path("/etc/letsencrypt/live")
    try:
        return sorted(p.name for p in live.iterdir() if p.is_dir())
    except OSError:
        return []


def composer_version():
    exe = Path("/usr/local/bin/composer")
    if not exe.is_file():
        return None
    try:
        out = subprocess.run([str(exe), "--version", "--no-interaction"], capture_output=True, text=True,
                             timeout=30, cwd="/", env={"COMPOSER_ALLOW_SUPERUSER": "1", "PATH": "/usr/bin:/bin",
                                                       "HOME": "/root"}).stdout
    except (OSError, subprocess.TimeoutExpired):
        return "installed"
    m = re.search(r"(\d+\.\d+\.\d+)", out)
    return m.group(1) if m else "installed"


def blocked(code, text, **extra):
    return {"code": code, "text": text, **extra}


def entry(c, have, cand, used):
    key = c["key"]
    pkgs = c.get("detect", [])
    pkg = next((p for p in pkgs if p in have), None)
    version = have.get(pkg) if pkg else None
    candidate = cand.get(pkg or (pkgs[0] if pkgs else ""))
    candidate = None if candidate in (None, "(none)") else candidate
    service = c.get("service")
    if key == "mysql" and pkg:
        service = mysql_service()
    if key == "php":
        vs = php_versions()
        pkg, version = ("php-fpm" if vs else None), (", ".join(vs) or None)
    elif key == "composer":
        version = composer_version()
        pkg = "composer" if version else None
    installed = pkg is not None
    act = active(service) if installed and service else None
    sites = used.get(key, [])
    how = c.get("how")
    update = bool(installed and candidate and version and candidate != version and key not in ("php", "composer"))
    if how is None:
        ib = blocked("managed_elsewhere", "PHP versions are managed in the PHP section") if key == "php" \
            else blocked("required_by_env", f"{c['title']} is part of simai-env")
    elif installed:
        ib = None if update else blocked("installed", f"{c['title']} is installed")
    elif not candidate and how == "apt":
        ib = blocked("unavailable", f"{c['title']} is not available from the configured repositories")
    else:
        ib = None
    if how is None:
        rb = blocked("managed_elsewhere", "PHP versions are removed in the PHP section") if key == "php" \
            else blocked("required_by_env", f"{c['title']} is part of simai-env")
    elif not installed:
        rb = blocked("not_installed", f"{c['title']} is not installed")
    elif sites:
        rb = blocked("used_by_sites", f"{c['title']} serves {len(sites)} site(s)", sites=sites)
    elif key == "certbot" and certificates():
        n = len(certificates())
        rb = blocked("has_certificates", f"Certbot renews {n} certificate(s)", count=n)
    else:
        rb = None
    packages = list(c.get("packages", []))
    if key == "postgresql" and installed:
        packages = sorted(p for p in have if re.fullmatch(r"postgresql(-\d+)?", p))
    ext = [f"php{v}-{c['php_ext']}" for v in php_versions()] if c.get("php_ext") else []
    state_ = "not_installed" if not installed else ("running" if act else "stopped" if act is False else "installed")
    return {"name": key, "key": key, "title": c["title"], "purpose": c["purpose"], "group": c["group"],
            "package": pkg, "installed": installed, "version": version, "candidate": candidate, "update": update,
            "service": service if installed else None, "unit": service, "active": act, "state": state_,
            "installable": how is not None and not installed and ib is None,
            "can_install": how is not None and not installed and ib is None,
            "can_update": update and how is not None, "can_remove": rb is None,
            "install_blocked": ib if not installed or not update else None, "remove_blocked": rb,
            "how": how, "packages": packages, "php_extensions": ext, "keeps": c.get("keeps", []), "sites": sites}


def state():
    names = sorted({p for c in CATALOG for p in c.get("detect", [])} | {"postgresql-%d" % n for n in range(9, 30)})
    have, cand = dpkg_versions(names), candidates(sorted({p for c in CATALOG for p in c.get("detect", [])}))
    used = {k: sites_by(k) for k in ("node", "apache", "postgresql", "mysql")}
    rows = [entry(c, have, cand, used) for c in CATALOG]
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


def one(key):
    """One catalogue entry without the system updates (for install/remove)."""
    c = next((c for c in CATALOG if c["key"] == key), None)
    if c is None:
        return None
    names = sorted(set(c.get("detect", [])) | ({"postgresql-%d" % n for n in range(9, 30)} if key == "postgresql" else set()))
    used = {key: sites_by(key)} if key in ("node", "apache", "postgresql", "mysql") else {}
    return entry(c, dpkg_versions(names), candidates(c.get("detect", [])), used)


def removal(pkgs, ext):
    """What `apt-get remove` would take away, and the protected packages among the rest."""
    out = run("apt-get", "-s", "-o", "Debug::NoLocking=1", "remove", *pkgs, *ext)
    removed = sorted({m.group(1) for m in re.finditer(r"^Remv (\S+)", out, re.M)})
    extra = [p for p in removed if p not in pkgs and p not in ext]
    # Parts of the program itself (postgresql-16-*, apache2-*) are expected.
    own = [p for p in extra if any(p.startswith(t + "-") for t in pkgs)]
    return removed, [p for p in extra if p not in own and PROTECTED.match(p)]


def main(argv):
    if argv[0] == "upgradable":
        for u in upgradable()[0]:
            if len(argv) < 2 or u["security"]:
                print(u["name"])
        return
    if argv[0] == "entry":
        e = one(argv[1]) if len(argv) > 1 else None
        if e is None:
            sys.exit(2)
        if e["installed"] and (e["packages"] or e["php_extensions"]):
            pk = [p for p in e["packages"] if p]
            ex = [p for p in e["php_extensions"] if p in dpkg_versions(e["php_extensions"])]
            e["removes"], e["removes_protected"] = removal(pk, ex)
        print(json.dumps(e))
        return
    if argv[0] == "node-sites":
        for s in node_sites():
            print(s)
        return
    data = state()
    if argv[0] == "json":
        print(json.dumps(data))
        return
    print(f"{'Program':<13}{'Group':<11}{'Version':<30}{'State':<15}Actions")
    for r in data["components"]:
        acts = [a for a, ok in (("install", r["can_install"]), ("update", r["can_update"]),
                                ("remove", r["can_remove"])) if ok]
        print(f"{r['key']:<13}{r['group']:<11}{(r['version'] or '-')[:29]:<30}{r['state']:<15}{', '.join(acts) or '-'}")
    s = data["system"]
    print(f"System updates: {s['updates']} (security {s['security']}), kept back: {len(s['kept_back'])}"
          f"{', reboot required' if s['reboot_required'] else ''}")


if __name__ == "__main__":
    main(sys.argv[1:])
