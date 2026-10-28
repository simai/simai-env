#!/usr/bin/env python3
"""Secret-free operation envelope. Handler text is deliberately not exposed."""
import json
import sys
import os
import fcntl
from pathlib import Path


def result(args):
    status, rc, key, target, operation, effect, output = args
    value = {
        "schema": "simai-command-result/1",
        "status": status,
        "exit_code": int(rc),
        "error_code": None if int(rc) in (0, 88, 89) else {
            "busy": "target_busy", "invalid": "invalid_options"
        }.get(status, "command_failed"),
        "command": key.replace(":", " ", 1),
        "target": target or "host",
        "operation_id": operation or None,
        "effects": effect,
        "applied": None if effect != "read" and status == "success" else False,
        "handler_executed": status not in {"planned", "invalid", "busy"},
        "checks": [{"name": "command_options", "status": "passed" if status != "invalid" else "failed"}],
        "verification": "not_run" if status == "planned" else "handler_exit_only",
    }
    # Only these audited handlers return structured, secret-free native data.
    if (status == "success" and key in {"self:describe", "site:describe", "self:commands", "self:ai-catalog", "logs:nginx"} or key == "site:doctor" and status in {"success", "failed"}) and output:
        try:
            value["data"] = json.loads(Path(output).read_text())
            if key == "site:doctor":
                value["verification"] = "diagnostic_checks"
                value["checks"].extend({
                    "name": f"diagnostic:{row['id']}", "title": row["title"], "area": row["area"],
                    "status": {"PASS": "passed", "WARN": "warning", "FAIL": "failed", "SKIP": "not_run"}[row["status"]]
                } for row in value["data"]["checks"])
        except (ValueError, OSError):
            value.update(status="failed", error_code="invalid_json_output", exit_code=1)
    json.dump(value, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return value["exit_code"]


if __name__ == "__main__":
    if sys.argv[1] == "record":
        path, key, rc, operation = sys.argv[2:]
        # Test instrumentation writes only to a root-owned receipt location.
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.write(json.dumps({"command": key, "exit_code": int(rc), "operation_id": operation,
                                     "evidence_kind": "handler_exit"}) + "\n")
        raise SystemExit(0)
    if sys.argv[1] != "result":
        raise SystemExit("unsupported operation")
    raise SystemExit(result(sys.argv[2:]))
