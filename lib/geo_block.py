#!/usr/bin/env python3
"""Country blocking (security center): nftables rules from the DB-IP Lite
country database (CC BY 4.0, https://db-ip.com).

Usage: geo_block.py check-db DB                 (rows and countries of a downloaded database)
       geo_block.py build ENV DB OUT KEEP       (write the nftables rules; KEEP: extra exempt addresses)
       geo_block.py status ENV DB OUTPUT
       geo_block.py lookup DB IP [OUTPUT]

ENV (geo.env): MODE=off|deny|allow, COUNTRIES=RU,CN, PORTS=web|all.
deny drops the listed countries, allow drops everyone else. web covers
TCP 80/443 and UDP 443 (HTTP/3), all covers every port, SSH included.
Loopback, private networks and this server's own addresses are never
dropped. The rules live in their own nftables table (inet simai_geo), which
runs before ufw and only ever drops.
"""
from __future__ import annotations

import gzip
import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path

TABLE = "simai_geo"
COUNTRY = re.compile(r"^[A-Z]{2}$")
PRIVATE4 = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"]
PRIVATE6 = ["::1/128", "fc00::/7", "fe80::/10"]
ATTRIBUTION = "IP to country data by DB-IP (https://db-ip.com), CC BY 4.0"


def env(path: str) -> dict:
    try:
        return dict(l.split("=", 1) for l in Path(path).read_text().splitlines() if "=" in l)
    except OSError:
        return {}


def rows(db: str):
    with gzip.open(db, "rt", errors="replace") as f:
        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 3:
                continue
            start, end, cc = parts[0].strip('"'), parts[1].strip('"'), parts[2].strip('"').upper()
            if COUNTRY.match(cc):
                yield start, end, cc


def check_db(db: str) -> dict:
    n, countries = 0, set()
    for _, _, cc in rows(db):
        n += 1
        countries.add(cc)
    return {"rows": n, "countries": len(countries)}


def own_addresses() -> list[str]:
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [a for a in out.split() if a]


def build(env_path: str, db: str, out: str, keep_extra: str) -> dict:
    e = env(env_path)
    mode = e.get("MODE", "off")
    countries = {c for c in e.get("COUNTRIES", "").split(",") if COUNTRY.match(c)}
    ports = e.get("PORTS", "web")
    v4, v6 = [], []
    if mode in ("deny", "allow"):
        for start, end, cc in rows(db):
            if cc in countries:
                # nftables 1.0.2 (Ubuntu 22.04) refuses a range of one address.
                (v6 if ":" in start else v4).append(start if start == end else f"{start}-{end}")
    keep4, keep6 = [], []
    if os.environ.get("SIMAI_GEO_NO_EXEMPT") != "1":  # tests only
        keep4, keep6 = list(PRIVATE4), list(PRIVATE6)
        for a in own_addresses():
            (keep6 if ":" in a else keep4).append(a)
    else:
        keep4, keep6 = ["127.0.0.0/8"], ["::1/128"]
    for a in filter(None, keep_extra.split(",")):
        try:
            ip = ipaddress.ip_network(a, strict=False)
        except ValueError:
            continue
        (keep6 if ip.version == 6 else keep4).append(str(ip))
    match = "" if ports == "all" else "meta l4proto { tcp, udp } th dport { 80, 443 } "

    def nset(name, kind, elements):
        body = f"        elements = {{ {', '.join(elements)} }}\n" if elements else ""
        return f"    set {name} {{\n        type {kind}; flags interval; auto-merge;\n{body}    }}\n"

    lines = [f"# simai-env country blocking: {mode} {','.join(sorted(countries))} on {ports} ports",
             f"# {ATTRIBUTION}",
             f"table inet {TABLE}", f"delete table inet {TABLE}", f"table inet {TABLE} {{",
             nset("keep4", "ipv4_addr", keep4), nset("keep6", "ipv6_addr", keep6),
             nset("c4", "ipv4_addr", v4), nset("c6", "ipv6_addr", v6),
             "    chain input {", "        type filter hook input priority -5; policy accept;",
             "        ip saddr @keep4 return", "        ip6 saddr @keep6 return"]
    if mode == "deny":
        lines += [f"        ip saddr @c4 {match}counter drop", f"        ip6 saddr @c6 {match}counter drop"]
    elif mode == "allow":
        lines += [f"        ip saddr != @c4 {match}counter drop", f"        ip6 saddr != @c6 {match}counter drop"]
    lines += ["    }", "}", ""]
    Path(out).write_text("\n".join(lines))
    os.chmod(out, 0o600)
    return {"mode": mode, "countries": sorted(countries), "ports": ports, "ranges_v4": len(v4), "ranges_v6": len(v6)}


def dropped() -> int | None:
    try:
        out = subprocess.run(["nft", "-j", "list", "table", "inet", TABLE], capture_output=True, text=True,
                             timeout=10).stdout
        data = json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    total = 0
    for item in data.get("nftables", []):
        for expr in (item.get("rule") or {}).get("expr", []):
            if "counter" in expr:
                total += int(expr["counter"].get("packets", 0))
    return total


def status(env_path: str, db: str, output: str) -> None:
    e = env(env_path)
    meta = env(str(Path(db).with_suffix(".meta")))
    active = dropped()
    data = {"schema": "simai-geo/1", "mode": e.get("MODE", "off"),
            "countries": [c for c in e.get("COUNTRIES", "").split(",") if c], "ports": e.get("PORTS", "web"),
            "active": active is not None, "dropped_packets": active,
            "database": {"date": meta.get("MONTH"), "downloaded_at": meta.get("AT"),
                         "rows": int(meta["ROWS"]) if meta.get("ROWS", "").isdigit() else None,
                         "present": Path(db).is_file()},
            "ranges": {"v4": int(e.get("RANGES_V4", 0) or 0), "v6": int(e.get("RANGES_V6", 0) or 0)},
            "attribution": ATTRIBUTION}
    if output == "json":
        print(json.dumps(data))
    else:
        print(f"Country blocking: {data['mode']}" + (f" {','.join(data['countries'])} on {data['ports']} ports"
                                                    if data["mode"] != "off" else ""))
        print(f"  database {data['database']['date'] or 'not downloaded'}; rules {'loaded' if data['active'] else 'not loaded'}"
              + (f", {active} packets dropped" if active is not None else ""))
        print(f"  {ATTRIBUTION}")


def lookup(db: str, ip: str, output: str) -> int:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        print("not an IP address", file=sys.stderr)
        return 1
    found = None
    for start, end, cc in rows(db):
        try:
            s, e = ipaddress.ip_address(start), ipaddress.ip_address(end)
        except ValueError:
            continue
        if s.version == addr.version and s <= addr <= e:
            found = cc
            break
    if output == "json":
        print(json.dumps({"schema": "simai-geo-lookup/1", "ip": ip, "country": found}))
    else:
        print(f"{ip}: {found or 'unknown'}")
    return 0


def main(argv: list[str]) -> int:
    mode = argv[0]
    if mode == "check-db":
        print(json.dumps(check_db(argv[1])))
        return 0
    if mode == "build":
        print(json.dumps(build(argv[1], argv[2], argv[3], argv[4] if len(argv) > 4 else "")))
        return 0
    if mode == "status":
        status(argv[1], argv[2], argv[3])
        return 0
    if mode == "lookup":
        return lookup(argv[1], argv[2], argv[3] if len(argv) > 3 else "human")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
