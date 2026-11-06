#!/usr/bin/env python3
"""MCP gate: the root side of simai-env's MCP server (admin/mcp_server.py).

The server runs as root through one fixed path: an AI client logs in over SSH
as the system account simai-mcp with a key that `mcp key-add` wrote into a
root-owned file, and the key's forced command starts
`sudo -n /usr/local/sbin/simai-mcp-session <role> <key>`. So the role (an
owner or the administrator) comes from the key, never from the client, and
code running as an owner (PHP of their sites) cannot reach it. Root on the
server may start the session directly.

Everything goes through the panel gateway (admin/panel_gate.py) with the
same rules and audit log; the actor is recorded as "mcp:<role>:<key>".
Actions take two steps: `plan` asks the gateway for the plan and keeps it
under a one-time token for 15 minutes; `confirm` runs exactly that plan.
So nothing changes before the plan was shown, and a confirmation cannot
smuggle other arguments.

Requests: {"op": "overview"}
          {"op": "read", "command": "site:describe", "args": {...}}
          {"op": "plan", "command": "cron:add", "args": {...}}
          {"op": "confirm", "token": "..."}
          {"op": "job", "job_id": "...", "log": false, "cursor": "0"}
"""
from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "admin"))
import panel_gate  # noqa: E402

STATE = Path(os.environ.get("SIMAI_MCP_STATE", "/var/lib/simai-env/mcp"))
CONFIG = Path(os.environ.get("SIMAI_MCP_CONFIG", "/etc/simai-env/mcp.env"))
OWNERS = Path(os.environ.get("SIMAI_OWNERS_DIR", "/etc/simai-env/owners"))
TOKEN = re.compile(r"^[a-f0-9]{32}$")
PLAN_TTL = 15 * 60


class Refused(Exception):
    pass


def config() -> dict:
    try:
        return dict(l.split("=", 1) for l in CONFIG.read_text().splitlines() if "=" in l)
    except OSError:
        return {}


ROLE = re.compile(r"^(admin|[a-z][a-z0-9-]{1,30})$")
KEY = re.compile(r"^[A-Za-z0-9+/]{8,64}$")


def identity(role: str, key: str = "local") -> tuple[str, str | None]:
    """(account, owner) for a session; owner None means the administrator."""
    if os.getuid() != 0:
        raise Refused("not_root")
    cfg = config()
    if cfg.get("ENABLED") != "yes":
        raise Refused("mcp_disabled")
    if not ROLE.match(role or "") or not (key == "local" or KEY.match(key or "")):
        raise Refused("bad_session")
    if role == "admin":
        return f"admin:{key[:12]}", None
    if not (OWNERS / role).is_file():
        raise Refused("owner_not_found")
    return f"{role}:{key[:12]}", role


def gate(request: dict) -> dict:
    p = subprocess.run([sys.executable, "-I", str(ROOT / "admin" / "panel_gate.py")],
                       input=(json.dumps(request) + "\n").encode(), capture_output=True, timeout=600,
                       env={**panel_gate.ENV, "SUDO_USER": "simai-mcp"})
    try:
        return json.loads(p.stdout.decode().splitlines()[0])
    except (ValueError, IndexError):
        return {"status": "failed", "reason": "gateway_error"}


def gate_request(account: str, owner: str | None, command: str, args: dict, confirm: bool = False) -> dict:
    req = {"schema": "simai-panel-request/1", "request_id": f"mcp-{secrets.token_hex(6)}",
           "actor": {"user": f"mcp:{account}", "owner": owner}, "command": command, "args": args}
    if confirm:
        req["confirm"] = True
    return gate(req)


def kind_of(command: str) -> str:
    if command not in panel_gate.ALLOW:
        raise Refused("unknown_command")
    if command.startswith("mcp:"):
        raise Refused("not_over_mcp")  # an assistant does not hand out MCP access
    return panel_gate.ALLOW[command][2]


def check_args(args) -> dict:
    if not isinstance(args, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in args.items()):
        raise Refused("args_must_be_strings")
    return args


def plans_dir() -> Path:
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    d = STATE / "plans"
    d.mkdir(mode=0o700, exist_ok=True)
    for f in d.glob("*.json"):
        try:
            if f.stat().st_mtime < time.time() - PLAN_TTL:
                f.unlink()
        except OSError:
            pass
    return d


def overview(account: str, owner: str | None) -> dict:
    commands = []
    for name in panel_gate.allowed_commands(owner):
        validators, required, kind = panel_gate.ALLOW[name]
        if kind == "download" or name in panel_gate.ATTACHMENT:
            continue  # files and archives do not travel through MCP
        if kind == "job" or name.startswith("mcp:"):
            continue  # jobs are followed with simai_job
        commands.append({"command": name, "kind": kind,
                         "args": {k: v.pattern for k, v in validators.items()}, "required": sorted(required)})
    return {"schema": "simai-mcp-overview/1", "account": account, "role": "owner" if owner else "administrator",
            "owner": owner, "commands": commands,
            "flow": "Read with simai_read. For an action call simai_plan, show the plan to the user, and only "
                    "after the user agrees call simai_confirm with the plan token; then follow the job with simai_job."}


def handle(req: dict, account: str, owner: str | None) -> dict:
    try:
        return run(req, account, owner)
    except Refused as e:
        return {"status": "refused", "reason": str(e)}


def run(req: dict, account: str, owner: str | None) -> dict:
    op = req.get("op")
    if op == "overview":
        return {"status": "ok", "data": overview(account, owner)}
    if op == "read":
        command = str(req.get("command", ""))
        if kind_of(command) not in ("read",):
            raise Refused("not_a_read_use_plan")
        return gate_request(account, owner, command, check_args(req.get("args") or {}))
    if op == "plan":
        command = str(req.get("command", ""))
        if kind_of(command) != "action" or command in panel_gate.ATTACHMENT:
            raise Refused("not_an_action")
        args = check_args(req.get("args") or {})
        answer = gate_request(account, owner, command, args)
        if answer.get("status") == "ok" and answer.get("kind") == "plan":
            token = secrets.token_hex(16)
            path = plans_dir() / f"{token}.json"
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as out:
                json.dump({"account": account, "owner": owner, "command": command, "args": args,
                           "created": time.time()}, out)
            answer["plan_token"] = token
            answer["expires_in"] = PLAN_TTL
        return answer
    if op == "confirm":
        token = str(req.get("token", ""))
        if not TOKEN.match(token):
            raise Refused("bad_token")
        path = plans_dir() / f"{token}.json"
        try:
            saved = json.loads(path.read_text())
            path.unlink()  # one use only
        except (OSError, ValueError):
            raise Refused("unknown_or_expired_token")
        if saved.get("account") != account or saved.get("owner") != owner:
            raise Refused("token_of_another_account")
        return gate_request(account, owner, saved["command"], saved["args"], confirm=True)
    if op == "job":
        job_id = str(req.get("job_id", ""))
        if req.get("log"):
            return gate_request(account, owner, "job:log", {"job_id": job_id, "after": str(req.get("cursor") or "0")})
        return gate_request(account, owner, "job:status", {"job_id": job_id})
    raise Refused("unknown_op")
