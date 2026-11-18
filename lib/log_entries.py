#!/usr/bin/env python3
"""Log lines as entries for the panel (logs nginx, service log; 1.60.0).

Usage: log_entries.py nginx-access|nginx-error|journal < lines
Prints a JSON list of entries: {at, level?, status?, method?, path?, ip?,
unit?, message?, raw}. `at` is ISO 8601 with the zone: the access log
carries its own; the error log is in the server's local time, so the
server's zone is added; journal entries come as journalctl JSON.
"""
import json
import re
import sys
from datetime import datetime, timezone

ACCESS = re.compile(r'^(?P<ip>\S+) \S+ \S+ \[(?P<at>[^\]]+)\] "(?P<method>[A-Z]+) (?P<path>\S+)[^"]*" (?P<status>\d{3}) ')
ERROR = re.compile(r"^(?P<at>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) \[(?P<level>[a-z]+)\] (?:\d+#\d+: )?(?:\*\d+ )?(?P<message>.*)$")
CLIENT = re.compile(r", client: (?P<ip>[0-9a-fA-F.:]+)")
REQUEST = re.compile(r', request: "(?P<method>[A-Z]+) (?P<path>\S+)')
PRIORITY = ["emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"]
LOCAL = datetime.now().astimezone().tzinfo


def access(line):
    m = ACCESS.match(line)
    if not m:
        return {"at": None, "raw": line}
    try:
        at = datetime.strptime(m["at"], "%d/%b/%Y:%H:%M:%S %z").isoformat()
    except ValueError:
        at = None
    return {"at": at, "status": int(m["status"]), "method": m["method"], "path": m["path"][:2000],
            "ip": m["ip"], "level": "error" if m["status"][0] == "5" else "warn" if m["status"][0] == "4" else "info",
            "raw": line}


def error(line):
    m = ERROR.match(line)
    if not m:
        return {"at": None, "raw": line}
    at = datetime.strptime(m["at"], "%Y/%m/%d %H:%M:%S").replace(tzinfo=LOCAL).isoformat()
    entry = {"at": at, "level": m["level"], "message": m["message"][:2000], "raw": line}
    for rx in (CLIENT, REQUEST):
        found = rx.search(m["message"])
        if found:
            entry.update(found.groupdict())
    return entry


def journal(line):
    try:
        row = json.loads(line)
    except ValueError:
        return {"at": None, "raw": line[:2000]}
    message = row.get("MESSAGE")
    if isinstance(message, list):  # journald sends non-UTF-8 text as bytes
        message = bytes(b & 0xFF for b in message if isinstance(b, int)).decode("utf-8", "replace")
    message = str(message or "")[:2000]
    try:
        at = datetime.fromtimestamp(int(row["__REALTIME_TIMESTAMP"]) / 1e6, timezone.utc).astimezone(LOCAL).isoformat()
    except (KeyError, ValueError, TypeError):
        at = None
    try:
        level = PRIORITY[int(row.get("PRIORITY", 6))]
    except (ValueError, IndexError):
        level = "info"
    unit = row.get("_SYSTEMD_UNIT") or row.get("SYSLOG_IDENTIFIER")
    ident = row.get("SYSLOG_IDENTIFIER") or unit or ""
    pid = row.get("_PID")
    raw = f"{at or ''} {ident}{f'[{pid}]' if pid else ''}: {message}"
    return {"at": at, "level": level, "unit": unit, "message": message, "raw": raw}


def main():
    kind = sys.argv[1] if len(sys.argv) == 2 else ""
    parse = {"nginx-access": access, "nginx-error": error, "journal": journal}.get(kind)
    if parse is None:
        print(__doc__, file=sys.stderr)
        return 2
    rows = sys.stdin.buffer.read().decode("utf-8", "replace").splitlines()
    json.dump([parse(r.rstrip("\n")) for r in rows if r.strip()], sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
