#!/usr/bin/env python3
"""Firewall rules (ufw) and address blocks for `firewall *` and `panel access`.

status OUTPUT SSH_PORTS ACTIVE INCOMING PANEL_DOMAIN ACCESS_FILE PENDING
                       rules from `ufw show added` on stdin; simai-firewall/1
find ID                the rule with this id (stdin as above), without "ufw "
protected ID SSH_PORTS exit 0 when the rule keeps SSH, HTTP or HTTPS open
addresses LIST         validate "any" or a comma list of addresses/CIDRs
block-add ADDRESS TTL  note a block (TTL seconds, 0 = until removed)
block-remove ADDRESS   forget a block (exit 2 when there is none)
blocks-expired         addresses whose block has run out
"""
import hashlib
import ipaddress
import json
import os
import re
import sys
import time
from pathlib import Path

BLOCKS = Path(os.environ.get("SIMAI_FIREWALL_BLOCKS", "/etc/simai-env/firewall/blocks.json"))
WEB_PORTS = {"80", "443"}
MAX_ADDRESSES = 50


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def rule_id(text):
    return hashlib.sha1(text.encode()).hexdigest()[:8]


def parse_rule(text):
    """ufw allow 22/tcp | ufw deny from 1.2.3.4 | ufw allow from X to any port 3306 proto tcp"""
    words = text.split()[1:]
    while words and words[0] in ("insert", "prepend"):
        words = words[2:] if words[0] == "insert" else words[1:]
    rule = {"id": rule_id(text), "rule": " ".join(words), "action": None, "port": None, "proto": None,
            "from": "any", "direction": "in"}
    if not words:
        return rule
    rule["action"] = words[0]
    rest = words[1:]
    if rest and rest[0] in ("in", "out"):
        rule["direction"] = rest[0]
        rest = rest[1:]
    if rest and re.match(r"^[0-9]+(:[0-9]+)?(/(tcp|udp))?$", rest[0]):
        port, _, proto = rest[0].partition("/")
        rule.update(port=port, proto=proto or "any")
        return rule
    for key, val in zip(rest, rest[1:]):
        if key == "from":
            rule["from"] = val
        elif key == "port":
            rule["port"] = val
        elif key == "proto":
            rule["proto"] = val
    if rule["port"] and not rule["proto"]:
        rule["proto"] = "any"
    return rule


def read_rules():
    out = []
    for line in sys.stdin:
        line = line.strip()
        if line.startswith("ufw "):
            out.append((line, parse_rule(line)))
    return out


def is_protected(rule, ssh_ports):
    keeps = set(ssh_ports) | WEB_PORTS
    return rule["action"] == "allow" and rule["direction"] == "in" and rule["from"] in ("any", "Anywhere") \
        and rule["port"] in keeps


def load_blocks():
    try:
        data = json.loads(BLOCKS.read_text())
        return data.get("blocks", []) if isinstance(data, dict) else []
    except (OSError, ValueError):
        return []


def save_blocks(blocks):
    BLOCKS.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = BLOCKS.with_name(BLOCKS.name + ".tmp")
    tmp.write_text(json.dumps({"schema": "simai-firewall-blocks/1", "blocks": blocks}, indent=1))
    os.chmod(tmp, 0o600)
    os.replace(tmp, BLOCKS)


def address(value):
    value = value.strip()
    try:
        net = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None
    return str(net.network_address) if net.num_addresses == 1 else str(net)


def panel_access(path):
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return "any"
    allowed = [l.split()[1].rstrip(";") for l in lines if l.startswith("allow ") and "# local" not in l]
    return allowed or "any"


def main(argv):
    action = argv[0] if argv else ""
    if action == "status":
        output, ssh, active, incoming, domain, access_file, pending = argv[1:8]
        ssh_ports = [p for p in ssh.split(",") if p]
        rules = []
        for _, r in read_rules():
            r["protected"] = is_protected(r, ssh_ports)
            rules.append(r)
        now = time.time()
        blocks = [{"address": b["address"], "until": iso(b["until"]) if b.get("until") else None,
                   "created_at": b.get("created_at")} for b in load_blocks()
                  if not b.get("until") or b["until"] > now]
        data = {"schema": "simai-firewall/1", "backend": "ufw", "active": active == "active",
                "default_incoming": incoming or None, "ssh_ports": [int(p) for p in ssh_ports],
                "rules": rules, "blocks": blocks,
                "panel_access": {"domain": domain, "allow": panel_access(access_file)} if domain else None,
                "pending_change": json.loads(pending) if pending else None}
        if output == "json":
            print(json.dumps(data))
            return
        print(f"Firewall      ufw {'active' if data['active'] else 'inactive'}, incoming {incoming or 'unknown'}")
        print(f"SSH ports     {', '.join(ssh_ports)}")
        for r in rules:
            print(f"  {r['id']}  {r['rule']}{'  (protected)' if r['protected'] else ''}")
        for b in blocks:
            print(f"  blocked {b['address']} until {b['until'] or 'removed'}")
        if domain:
            allow = data["panel_access"]["allow"]
            print(f"Panel access  {domain}: {'any address' if allow == 'any' else ', '.join(allow)}")
        if data["pending_change"]:
            p = data["pending_change"]
            print(f"Pending       {p['change_id']} ({p['kind']}) until {p['expires_at']}: {p['summary']}")
    elif action == "find":
        for text, r in read_rules():
            if r["id"] == argv[1]:
                print(r["rule"])
                return
        sys.exit(2)
    elif action == "protected":
        for _, r in read_rules():
            if r["id"] == argv[1]:
                sys.exit(0 if is_protected(r, [p for p in argv[2].split(",") if p]) else 1)
        sys.exit(2)
    elif action == "addresses":
        value = argv[1].strip()
        if value == "any":
            print("any")
            return
        items = [v for v in value.split(",") if v.strip()]
        if not 0 < len(items) <= MAX_ADDRESSES:
            sys.exit(f"Give 1-{MAX_ADDRESSES} addresses or CIDR blocks, or any")
        out = []
        for v in items:
            a = address(v)
            if a is None:
                sys.exit(f"Not an IP address or CIDR block: {v.strip()}")
            if a not in out:
                out.append(a)
        print("\n".join(out))
    elif action == "block-add":
        addr, ttl = argv[1], int(argv[2])
        now = time.time()
        blocks = [b for b in load_blocks() if b["address"] != addr]
        blocks.append({"address": addr, "until": now + ttl if ttl else None, "created_at": iso(now)})
        save_blocks(blocks)
    elif action == "block-remove":
        blocks = load_blocks()
        rest = [b for b in blocks if b["address"] != argv[1]]
        if len(rest) == len(blocks):
            sys.exit(2)
        save_blocks(rest)
    elif action == "blocks-expired":
        now = time.time()
        for b in load_blocks():
            if b.get("until") and b["until"] <= now:
                print(b["address"])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
