#!/usr/bin/env python3
"""Where the panel answers: the server's address on its own port, and a
domain attached later.

The panel is an ordinary site (`panel install`). Without a domain it gets the
internal name panel.internal and answers on https://<server address>:<port>
(8500 by default) with a self-signed certificate. A domain attached later
(`panel domain`) answers on 80 and, after its Let's Encrypt certificate, on
443. Both are copies of the panel site's own server block (its root, PHP
pool, access list, headers and locations) with other listen lines, written
to one nginx file outside the site list; `sync` writes it again when the
site's block changes.

State: /etc/simai-env/panel-address.json
  {"port": 8500, "ip_access": true, "domain": null, "domain_ssl": false}

Usage: panel_address.py render SITE_CONF CERT KEY      nginx text on stdout
       panel_address.py get KEY | set KEY VALUE         state
       panel_address.py ip                              the server's address
       panel_address.py describe SITE_DOMAIN CERT [json] simai-panel-address/1
       panel_address.py port-ok PORT                    exit 1 if not usable
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

STATE = Path(os.environ.get("SIMAI_PANEL_ADDRESS_STATE", "/etc/simai-env/panel-address.json"))
DEFAULTS = {"port": 8500, "ip_access": True, "domain": None, "domain_ssl": False}
INTERNAL = "panel.internal"
DOMAIN = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
# Ports the server or common services already use; the panel must not take them.
RESERVED = {20, 21, 22, 25, 53, 80, 110, 143, 443, 465, 587, 993, 995, 3306, 5432, 6379, 11211}
DROP = re.compile(r"^\s*(listen|server_name|http2|ssl_[a-z_]+)\b|Strict-Transport-Security")


def state() -> dict:
    try:
        data = json.loads(STATE.read_text())
    except (OSError, ValueError):
        data = {}
    return {**DEFAULTS, **{k: v for k, v in data.items() if k in DEFAULTS}}


def save(data: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE.parent, prefix=".panel-address.")
    with os.fdopen(fd, "w") as out:
        json.dump(data, out, indent=1)
        out.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATE)


def server_blocks(text: str) -> list[str]:
    """Top-level `server { ... }` blocks of an nginx file (comments skipped)."""
    blocks, depth, start = [], 0, None
    clean = re.sub(r"#[^\n]*", lambda m: " " * len(m.group()), text)
    for m in re.finditer(r"\bserver\s*\{|\{|\}", clean):
        tok = m.group()
        if tok.startswith("server") and depth == 0:
            start, depth = m.start(), 1
        elif tok.endswith("{"):
            depth += 1 if depth else 0
        elif tok == "}" and depth:
            depth -= 1
            if depth == 0 and start is not None:
                blocks.append(text[start:m.end()])
                start = None
    return blocks


def site_body(conf: str) -> list[str]:
    """The lines inside the panel site's main server block, without its
    listen, server name, TLS settings and HTTP-to-HTTPS redirect."""
    blocks = [b for b in server_blocks(conf) if "fastcgi_pass" in b or "proxy_pass" in b] or server_blocks(conf)
    if not blocks:
        raise SystemExit("no server block in the panel site configuration")
    lines = blocks[0].split("\n")[1:-1]
    out, skip = [], False
    for line in lines:
        if "simai-ssl-redirect-start" in line:
            skip = True
        if not skip and not DROP.search(line):
            out.append(line)
        if "simai-ssl-redirect-end" in line:
            skip = False
    return out


def http2_lines(listen: str) -> list[str]:
    """`listen ... ssl` lines in the form this nginx understands."""
    new = os.environ.get("SIMAI_NGINX_HTTP2_DIRECTIVE", "yes") == "yes"
    return [f"    {listen};", "    http2 on;"] if new else [f"    {listen} http2;"]


def render(conf_path: str, cert: str, key: str) -> str:
    st, body = state(), site_body(Path(conf_path).read_text())
    out = ["# simai-env: where the panel answers (panel address, panel port, panel domain).",
           "# Written by simai-admin.sh panel; edits here are replaced.", ""]
    if st["ip_access"]:
        port = int(st["port"])
        out += ["server {"] + http2_lines(f"listen {port} ssl default_server") \
            + [f"    listen [::]:{port} ssl default_server;", "    server_name _;",
               f"    ssl_certificate {cert};", f"    ssl_certificate_key {key};",
               "    # Plain HTTP sent to this port: send the browser to HTTPS.",
               f"    error_page 497 =301 https://$host:{port}$request_uri;"] + body + ["}", ""]
        if st["domain"] and st["domain_ssl"]:
            # The attached domain on the same port answers with its own
            # certificate, so https://<domain>:<port> has no browser warning.
            live = f"/etc/letsencrypt/live/{st['domain']}"
            out += ["server {"] + http2_lines(f"listen {port} ssl") \
                + [f"    listen [::]:{port} ssl;", f"    server_name {st['domain']};",
                   f"    ssl_certificate {live}/fullchain.pem;", f"    ssl_certificate_key {live}/privkey.pem;",
                   f"    error_page 497 =301 https://$host:{port}$request_uri;"] + body + ["}", ""]
    if st["domain"]:
        d = st["domain"]
        live = f"/etc/letsencrypt/live/{d}"
        if st["domain_ssl"]:
            out += ["server {", "    listen 80;", "    listen [::]:80;", f"    server_name {d};"]
            out += acme_block(body) + ["    location / {", "        return 301 https://$host$request_uri;", "    }",
                                        "}", ""]
            out += ["server {"] + http2_lines("listen 443 ssl") + ["    listen [::]:443 ssl;", f"    server_name {d};",
                     f"    ssl_certificate {live}/fullchain.pem;", f"    ssl_certificate_key {live}/privkey.pem;",
                     '    add_header Strict-Transport-Security "max-age=31536000" always;'] + body + ["}", ""]
        else:
            out += ["server {", "    listen 80;", "    listen [::]:80;", f"    server_name {d};"] + body + ["}", ""]
    return "\n".join(out)


def acme_block(body: list[str]) -> list[str]:
    """The site's ACME challenge location, so certificates renew over HTTP."""
    out, inside = [], False
    for line in body:
        if "location" in line and "acme-challenge" in line:
            inside = True
        if inside:
            out.append(line)
            if line.strip() == "}":
                break
    return out


def addresses() -> list[str]:
    """Addresses of this server: the outgoing one first."""
    found = []
    try:
        r = subprocess.run(["ip", "-o", "route", "get", "1.1.1.1"], capture_output=True, text=True, timeout=5)
        m = re.search(r"\bsrc (\S+)", r.stdout)
        if m:
            found.append(m.group(1))
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        r = subprocess.run(["ip", "-o", "addr", "show", "scope", "global"], capture_output=True, text=True, timeout=5)
        for m in re.finditer(r"\binet6? ([0-9a-f.:]+)/", r.stdout):
            if m.group(1) not in found:
                found.append(m.group(1))
    except (OSError, subprocess.SubprocessError):
        pass
    return found


def public_ip() -> str | None:
    addrs = addresses()
    for a in addrs:
        try:
            if ipaddress.ip_address(a).is_global:
                return a
        except ValueError:
            pass
    return addrs[0] if addrs else None


def url_host(ip: str) -> str:
    return f"[{ip}]" if ":" in ip else ip


def resolves_here(domain: str) -> tuple[bool, list[str]]:
    try:
        got = sorted({ai[4][0] for ai in socket.getaddrinfo(domain, 80, proto=socket.IPPROTO_TCP)})
    except OSError:
        return False, []
    mine = set(addresses())
    return bool(got) and any(g in mine for g in got), got


def cert_facts(cert: str) -> dict:
    try:
        r = subprocess.run(["openssl", "x509", "-in", cert, "-noout", "-fingerprint", "-sha256", "-enddate"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return {}
    fp = re.search(r"Fingerprint=([0-9A-F:]+)", r.stdout)
    end = re.search(r"notAfter=(.+)", r.stdout)
    return {"sha256": fp.group(1) if fp else None, "expires": end.group(1).strip() if end else None}


def describe(site_domain: str, cert: str) -> dict:
    st, ip = state(), public_ip()
    own = site_domain if site_domain and site_domain != INTERNAL else None
    domain = st["domain"] or own
    domain_ssl = st["domain_ssl"] if st["domain"] else bool(own and Path(f"/etc/letsencrypt/live/{own}").exists())
    ip_url = f"https://{url_host(ip)}:{st['port']}" if st["ip_access"] and ip else None
    domain_url = f"{'https' if domain_ssl else 'http'}://{domain}" if domain else None
    return {"schema": "simai-panel-address/1", "installed": bool(site_domain), "site_domain": site_domain or None,
            "ip": ip, "addresses": addresses(), "port": st["port"], "ip_access": st["ip_access"], "ip_url": ip_url,
            "ip_certificate": {"kind": "self-signed", **cert_facts(cert)} if st["ip_access"] and Path(cert).exists() else None,
            "domain": domain, "domain_ssl": domain_ssl, "domain_url": domain_url,
            "domain_managed": bool(st["domain"]), "url": domain_url if domain_ssl else (ip_url or domain_url)}


def port_ok(port: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]{2,4}", port or "") or not 100 <= int(port) <= 65535:
        print("--port must be 100-65535", file=sys.stderr)
        return 1
    if int(port) in RESERVED:
        print(f"port {port} belongs to another service (SSH, web, mail, databases)", file=sys.stderr)
        return 1
    if int(port) == int(state()["port"]):
        return 0
    try:
        r = subprocess.run(["ss", "-Htlnp", f"sport = :{port}"], capture_output=True, text=True, timeout=5)
        if r.stdout.strip():
            print(f"port {port} is already taken by: {r.stdout.split()[-1][:120]}", file=sys.stderr)
            return 1
    except (OSError, subprocess.SubprocessError):
        pass
    return 0


def main(argv: list[str]) -> int:
    if argv[:1] == ["render"] and len(argv) == 4:
        sys.stdout.write(render(argv[1], argv[2], argv[3]))
        return 0
    if argv[:1] == ["get"] and len(argv) == 2:
        v = state().get(argv[1])
        print("" if v is None else ("yes" if v is True else "no" if v is False else v))
        return 0
    if argv[:1] == ["set"] and len(argv) == 3:
        key, value = argv[1], argv[2]
        st = state()
        if key == "port":
            st["port"] = int(value)
        elif key in ("ip_access", "domain_ssl"):
            st[key] = value == "yes"
        elif key == "domain":
            if value and not DOMAIN.match(value):
                print("not a domain name", file=sys.stderr)
                return 1
            st["domain"], st["domain_ssl"] = (value or None), False
        else:
            return 2
        save(st)
        return 0
    if argv == ["ip"]:
        print(public_ip() or "")
        return 0
    if argv[:1] == ["resolves"] and len(argv) == 2:
        ok, got = resolves_here(argv[1])
        print(" ".join(got))
        return 0 if ok else 1
    if argv[:1] == ["describe"] and len(argv) in (3, 4):
        data = describe(argv[1], argv[2])
        if argv[3:] == ["json"]:
            print(json.dumps(data, ensure_ascii=False))
        else:
            for k in ("url", "ip_url", "domain_url", "port", "ip_access", "domain", "domain_ssl"):
                print(f"{k + ':':<12} {'-' if data[k] is None else data[k]}")
            if data["ip_certificate"]:
                print(f"{'cert:':<12} self-signed, SHA-256 {data['ip_certificate'].get('sha256')}")
        return 0
    if argv[:1] == ["port-ok"] and len(argv) == 2:
        return port_ok(argv[1])
    print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
