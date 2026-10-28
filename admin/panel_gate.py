#!/usr/bin/env python3
"""Panel gateway: one JSON request on stdin, one JSON answer on stdout.

Runs as root through a single sudo rule for the panel account (see
admin/commands/panel.sh and docs/architecture/panel-gate.md). Only allowlisted
commands with validated arguments reach simai-admin.sh, always as an argv
list and with `--output json`; nothing from the request is ever interpreted
by a shell.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = str(ROOT / "simai-admin.sh")
LOG = os.environ.get("SIMAI_PANEL_GATE_LOG", "/var/log/simai-panel-gate.log")
MAX_REQUEST = 64 * 1024
TIMEOUT = 300

DOMAIN = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$")
YES_NO = re.compile(r"^(yes|no)$")
REQUEST_ID = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
OWNER = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")

# Stage 1: read-only commands whose answers are structured and secret-free
# (lib/command_contract.py). command -> {argument: validator}, required set.
ALLOW = {
    "self:describe": ({}, set()),
    "self:commands": ({}, set()),
    "site:describe": ({"domain": DOMAIN}, {"domain"}),
    "site:doctor": ({"domain": DOMAIN, "strict": YES_NO, "include-target": YES_NO}, {"domain"}),
}
HOST_COMMANDS = {"self:describe"}  # owners get a filtered view


class Refused(Exception):
    pass


def text(value, limit):
    return isinstance(value, str) and 0 < len(value) <= limit and value.isprintable()


def parse(raw):
    if len(raw) > MAX_REQUEST:
        raise Refused("too_large")
    try:
        req = json.loads(raw)
    except ValueError:
        raise Refused("bad_request")
    if not isinstance(req, dict) or req.get("schema") != "simai-panel-request/1":
        raise Refused("bad_request")
    if not isinstance(req.get("request_id"), str) or not REQUEST_ID.match(req["request_id"]):
        raise Refused("bad_request")
    actor = req.get("actor")
    if not isinstance(actor, dict) or not text(actor.get("user"), 254):
        raise Refused("bad_actor")
    owner = actor.get("owner")
    if owner is not None and not (isinstance(owner, str) and OWNER.match(owner)):
        raise Refused("bad_actor")
    by = actor.get("impersonated_by")
    if by is not None and not text(by, 254):
        raise Refused("bad_actor")
    command = req.get("command")
    if command not in ALLOW:
        raise Refused("not_allowed")
    args = req.get("args", {})
    if not isinstance(args, dict):
        raise Refused("invalid_argument")
    validators, required = ALLOW[command]
    for name, value in args.items():
        if name not in validators or not isinstance(value, str) or not validators[name].match(value):
            raise Refused("invalid_argument")
    if not required <= set(args):
        raise Refused("invalid_argument")
    if req.get("confirm", False) is not False:
        raise Refused("not_allowed")  # stage 1 changes nothing
    return req, command, args, owner


def run(command, args):
    section, name = command.split(":", 1)
    argv = [CLI, section, name]
    for key, value in args.items():
        argv += [f"--{key}", value]
    argv += ["--output", "json"]
    env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
           "LANG": "C.UTF-8", "SIMAI_ADMIN_MENU": "0", "HOME": "/root"}
    try:
        proc = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                              env=env, timeout=TIMEOUT, cwd="/")
    except subprocess.TimeoutExpired:
        return None
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return None


def owner_view(describe, owner):
    """The host description reduced to one owner's sites."""
    data = dict(describe)
    data["sites"] = [s for s in describe.get("sites", []) if s.get("owner") == owner]
    data.pop("isolation", None)
    data.pop("next", None)
    return data


def owned(owner, domain):
    result = run("self:describe", {})
    sites = (result or {}).get("data", {}).get("sites", [])
    return any(s.get("domain") == domain and s.get("owner") == owner for s in sites)


def log(entry):
    try:
        fd = os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a") as stream:
            stream.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def main():
    started = time.time()
    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
    answer = {"schema": "simai-panel-answer/1", "request_id": None}
    entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
             "caller": os.environ.get("SUDO_USER", "")}
    try:
        req, command, args, owner = parse(raw)
        answer["request_id"] = req["request_id"]
        entry.update(request_id=req["request_id"], user=req["actor"]["user"], owner=owner,
                     impersonated_by=req["actor"].get("impersonated_by"), command=command,
                     domain=args.get("domain"))
        if owner is not None and "domain" in args and not owned(owner, args["domain"]):
            raise Refused("owner_scope")
        result = run(command, args)
        if result is None or result.get("schema") != "simai-command-result/1":
            answer.update(status="failed", reason="invalid_output")
        elif "data" not in result:
            answer.update(status="failed", reason=result.get("error_code") or "command_failed",
                          operation_id=result.get("operation_id"))
        else:
            data = result["data"]
            if owner is not None and command in HOST_COMMANDS:
                data = owner_view(data, owner)
            # site:doctor reports failed checks as data, not as a gateway failure.
            answer.update(status="ok", kind="result", data=data,
                          command_status=result.get("status"),
                          operation_id=result.get("operation_id"))
    except Refused as refusal:
        answer.update(status="refused", reason=str(refusal))
    entry.update(status=answer["status"], reason=answer.get("reason"),
                 operation_id=answer.get("operation_id"), ms=int((time.time() - started) * 1000))
    log(entry)
    json.dump(answer, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
