#!/usr/bin/env python3
"""A site's extra names: www and other domains that show the site or send
the visitor to its main domain.

State: /etc/simai-env/sites/<domain>/names.json
  {"names": [{"name": "www.example.com", "mode": "redirect"}, ...]}

- mode "serve": the name is added to the site's own server_name, so the site
  answers on it as on its main domain.
- mode "redirect": the name answers 301 to the main domain from a small
  nginx file of its own, /etc/nginx/conf.d/simai-site-names-<domain>.conf,
  which also serves the site's ACME location so its certificate can cover
  the name.

Usage: site_names.py list DOMAIN                      "name mode" lines
       site_names.py serve DOMAIN                     serve-mode names, one line
       site_names.py add DOMAIN NAME MODE | remove DOMAIN NAME
       site_names.py taken NAME [EXCEPT_DOMAIN]       exit 0 and the owner if taken
       site_names.py render DOMAIN SITE_CONF          the redirect file on stdout
       site_names.py cert-names DOMAIN                names the certificate should hold
       site_names.py describe DOMAIN [json]           simai-site-names/1
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

SITES = Path(os.environ.get("SIMAI_SITES_STATE", "/etc/simai-env/sites"))
NGINX = Path(os.environ.get("SIMAI_NGINX_SITES", "/etc/nginx/sites-available"))
CONFD = Path(os.environ.get("SIMAI_NGINX_CONFD", "/etc/nginx/conf.d"))
PANEL = Path(os.environ.get("SIMAI_PANEL_ADDRESS_STATE", "/etc/simai-env/panel-address.json"))
LIVE = Path(os.environ.get("SIMAI_LETSENCRYPT_LIVE", "/etc/letsencrypt/live"))
DOMAIN = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
MODES = ("serve", "redirect")
MAX_NAMES = 20


def state_file(domain: str) -> Path:
    return SITES / domain / "names.json"


def load(domain: str) -> list[dict]:
    try:
        data = json.loads(state_file(domain).read_text())
    except (OSError, ValueError):
        return []
    out = []
    for item in data.get("names", []) if isinstance(data, dict) else []:
        if isinstance(item, dict) and DOMAIN.match(str(item.get("name", ""))) and item.get("mode") in MODES:
            out.append({"name": item["name"], "mode": item["mode"]})
    return out


def save(domain: str, names: list[dict]) -> None:
    path = state_file(domain)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".names.")
    with os.fdopen(fd, "w") as out:
        json.dump({"names": names}, out, indent=1)
        out.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def server_names(text: str) -> set[str]:
    found = set()
    for m in re.finditer(r"^\s*server_name\s+([^;]+);", re.sub(r"#[^\n]*", "", text), re.M):
        found.update(t.lower() for t in m.group(1).split())
    return found


def taken(name: str, except_domain: str = "") -> str | None:
    """The site (or "panel") that already answers on this name."""
    for conf in sorted(NGINX.glob("*.conf")):
        site = conf.name[:-5]
        if site == except_domain:
            continue
        try:
            names = server_names(conf.read_text())
        except OSError:
            continue
        if name in names or site == name:
            return site
    for state in sorted(SITES.glob("*/names.json")):
        site = state.parent.name
        if site != except_domain and any(n["name"] == name for n in load(site)):
            return site
    try:
        panel = json.loads(PANEL.read_text())
        if panel.get("domain") == name:
            return "panel"
    except (OSError, ValueError):
        pass
    return None


def acme_block(conf_text: str) -> list[str]:
    out, inside = [], False
    for line in conf_text.split("\n"):
        if "location" in line and "acme-challenge" in line:
            inside = True
        if inside:
            out.append(line)
            if line.strip() == "}":
                break
    return out


def cert_names(domain: str) -> list[str]:
    try:
        r = subprocess.run(["openssl", "x509", "-in", str(LIVE / domain / "fullchain.pem"), "-noout", "-ext",
                            "subjectAltName"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return []
    return re.findall(r"DNS:([^,\s]+)", r.stdout)


def render(domain: str, site_conf: str) -> str:
    """nginx text for the redirect names, or "" when there are none."""
    redirect = [n["name"] for n in load(domain) if n["mode"] == "redirect"]
    if not redirect:
        return ""
    text = Path(site_conf).read_text()
    acme = acme_block(text)
    https_site = bool(re.search(r"^\s*listen\s+(\[::\]:)?443\b", text, re.M))
    target = f"{'https' if https_site else 'http'}://{domain}$request_uri"
    names = " ".join(redirect)
    out = [f"# simai-env: extra names of {domain} sent to it (site names). Edits here are replaced.", "",
           "server {", "    listen 80;", "    listen [::]:80;", f"    server_name {names};"]
    out += acme + ["    location / {", f"        return 301 {target};", "    }", "}", ""]
    covered = set(cert_names(domain))
    secure = [n for n in redirect if n in covered]
    if https_site and secure:
        live = LIVE / domain
        out += ["server {", "    listen 443 ssl;", "    listen [::]:443 ssl;", f"    server_name {' '.join(secure)};",
                f"    ssl_certificate {live}/fullchain.pem;", f"    ssl_certificate_key {live}/privkey.pem;",
                f"    return 301 https://{domain}$request_uri;", "}", ""]
    return "\n".join(out)


def addresses() -> set[str]:
    found = set()
    try:
        r = subprocess.run(["ip", "-o", "addr", "show", "scope", "global"], capture_output=True, text=True, timeout=5)
        found.update(re.findall(r"\binet6? ([0-9a-f.:]+)/", r.stdout))
    except (OSError, subprocess.SubprocessError):
        pass
    return found


def dns(name: str, mine: set[str]) -> dict:
    try:
        got = sorted({ai[4][0] for ai in socket.getaddrinfo(name, 80, proto=socket.IPPROTO_TCP)})
    except OSError:
        return {"points_here": False, "addresses": []}
    return {"points_here": bool(got) and any(g in mine for g in got) if mine else None, "addresses": got}


def describe(domain: str) -> dict:
    conf = NGINX / f"{domain}.conf"
    try:
        text = conf.read_text()
    except OSError:
        text = ""
    own = server_names(text)
    mine = addresses()
    covered = set(cert_names(domain))
    https_site = bool(re.search(r"^\s*listen\s+(\[::\]:)?443\b", text, re.M))

    def covers(name):
        return https_site and (name in covered or any(c.startswith("*.") and name.endswith(c[1:])
                                                       and name.count(".") == c.count(".") for c in covered))

    rows = [{"name": domain, "kind": "primary", "mode": "serve", "dns": dns(domain, mine), "https": covers(domain)}]
    for n in load(domain):
        rows.append({"name": n["name"], "kind": "extra", "mode": n["mode"], "dns": dns(n["name"], mine),
                     "https": covers(n["name"])})
    for w in sorted(x for x in own if x.startswith("*.")):
        rows.append({"name": w, "kind": "wildcard", "mode": "serve", "dns": {"points_here": None, "addresses": []},
                     "https": covers(w)})
    certificate = None
    if covered:
        try:
            r = subprocess.run(["openssl", "x509", "-in", str(LIVE / domain / "fullchain.pem"), "-noout", "-enddate",
                                "-issuer", "-nameopt", "multiline"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            r = ""
        end = re.search(r"notAfter=(.+)", r)
        org = re.search(r"^\s+organizationName\s*=\s*(.+)$", r, re.M)
        certificate = {"names": sorted(covered), "issuer": org.group(1).strip() if org else None,
                       "auto_renew": Path(f"/etc/letsencrypt/renewal/{domain}.conf").is_file(),
                       "not_after": end.group(1).strip() if end else None}
    names = {r["name"] for r in rows}
    suggest = [f"www.{domain}"] if not domain.startswith("www.") and f"www.{domain}" not in names else []
    return {"schema": "simai-site-names/1", "domain": domain, "names": rows, "certificate": certificate,
            "max": MAX_NAMES, "suggest": suggest}


def main(argv: list[str]) -> int:
    cmd, args = (argv[0], argv[1:]) if argv else ("", [])
    if cmd == "list" and len(args) == 1:
        for n in load(args[0]):
            print(n["name"], n["mode"])
        return 0
    if cmd == "serve" and len(args) == 1:
        print(" ".join(n["name"] for n in load(args[0]) if n["mode"] == "serve"))
        return 0
    if cmd == "add" and len(args) == 3:
        domain, name, mode = args
        if not DOMAIN.match(name) or mode not in MODES:
            print("not a domain name, or mode is not serve|redirect", file=sys.stderr)
            return 2
        names = [n for n in load(domain) if n["name"] != name]
        if len(names) >= MAX_NAMES:
            print(f"a site has at most {MAX_NAMES} extra names", file=sys.stderr)
            return 3
        save(domain, names + [{"name": name, "mode": mode}])
        return 0
    if cmd == "remove" and len(args) == 2:
        save(args[0], [n for n in load(args[0]) if n["name"] != args[1]])
        return 0
    if cmd == "taken" and len(args) in (1, 2):
        owner = taken(args[0], args[1] if len(args) == 2 else "")
        if owner:
            print(owner)
            return 0
        return 1
    if cmd == "render" and len(args) == 2:
        sys.stdout.write(render(args[0], args[1]))
        return 0
    if cmd == "cert-names" and len(args) == 1:
        print(" ".join([args[0]] + [n["name"] for n in load(args[0])]))
        return 0
    if cmd == "describe" and len(args) in (1, 2):
        data = describe(args[0])
        if args[1:] == ["json"]:
            print(json.dumps(data, ensure_ascii=False))
        else:
            for row in data["names"]:
                dns_s = {True: "points here", False: "elsewhere", None: "-"}[row["dns"]["points_here"]]
                print(f"{row['name']:<40} {row['kind']:<9} {row['mode']:<9} https={'yes' if row['https'] else 'no':<4} dns: {dns_s}")
        return 0
    print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
