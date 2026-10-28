#!/usr/bin/env python3
"""Panel gateway: one JSON request on stdin, one JSON answer on stdout.

Read commands answer data; actions answer a plan, and with `confirm` start a
job (a transient systemd unit) that job:status, job:log and job:cancel follow.

Runs as root through a single sudo rule for the panel account (see
admin/commands/panel.sh and docs/architecture/panel-gate.md). Only allowlisted
commands with validated arguments reach simai-admin.sh, always as an argv
list and with `--output json`; nothing from the request is ever interpreted
by a shell.
"""
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = str(ROOT / "simai-admin.sh")
LOG = os.environ.get("SIMAI_PANEL_GATE_LOG", "/var/log/simai-panel-gate.log")
JOBS = Path(os.environ.get("SIMAI_PANEL_JOBS", "/var/lib/simai-env/panel-jobs"))
MAX_REQUEST = 64 * 1024
TIMEOUT = 300
JOB_KEEP_DAYS = 30
MAX_LOG_LINES = 1000
ENV = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
       "LANG": "C.UTF-8", "SIMAI_ADMIN_MENU": "0", "HOME": "/root"}

DOMAIN = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+$")
YES_NO = re.compile(r"^(yes|no)$")
REQUEST_ID = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
OWNER = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
EMAIL = re.compile(r"^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,63}$")
LINES = re.compile(r"^(?:[1-9][0-9]{0,2}|1000)$")
JOB_ID = re.compile(r"^[a-f0-9]{24}$")
CURSOR = re.compile(r"^[0-9]{1,7}$")
KIND = re.compile(r"^(access|error)$")

# command -> (arguments with validators, required arguments, kind). Read
# commands answer structured, secret-free data (lib/command_contract.py);
# action commands answer a plan, and with confirm a job.
ALLOW = {
    "self:describe": ({}, set(), "read"),
    "self:commands": ({}, set(), "read"),
    "site:describe": ({"domain": DOMAIN}, {"domain"}, "read"),
    "site:doctor": ({"domain": DOMAIN, "strict": YES_NO, "include-target": YES_NO}, {"domain"}, "read"),
    "logs:nginx": ({"domain": DOMAIN, "kind": KIND, "lines": LINES}, {"domain"}, "read"),
    "ssl:letsencrypt": ({"domain": DOMAIN, "email": EMAIL, "redirect": YES_NO, "hsts": YES_NO, "staging": YES_NO},
                        {"domain", "email"}, "action"),
    "ssl:renew": ({"domain": DOMAIN}, {"domain"}, "action"),
    "site:deploy-rollback": ({"domain": DOMAIN}, {"domain"}, "action"),
    "backup:data": ({"domain": DOMAIN, "db": YES_NO, "files": YES_NO}, {"domain"}, "action"),
    "queue:restart": ({"domain": DOMAIN}, {"domain"}, "action"),
    "site:service-restart": ({"domain": DOMAIN}, {"domain"}, "action"),
    "job:status": ({"job_id": JOB_ID}, {"job_id"}, "job"),
    "job:log": ({"job_id": JOB_ID, "after": CURSOR}, {"job_id"}, "job"),
    "job:cancel": ({"job_id": JOB_ID}, {"job_id"}, "job"),
    "job:list": ({}, set(), "job"),
}
HOST_COMMANDS = {"self:describe"}  # owners get a filtered view


class Refused(Exception):
    pass


class Done(Exception):
    """The answer is complete."""


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
    validators, required, kind = ALLOW[command]
    for name, value in args.items():
        if name not in validators or not isinstance(value, str) or not validators[name].match(value):
            raise Refused("invalid_argument")
    if not required <= set(args):
        raise Refused("invalid_argument")
    confirm = req.get("confirm", False)
    if confirm not in (False, True) or (confirm and kind != "action"):
        raise Refused("not_allowed")  # only actions are confirmed
    return req, command, args, owner


def argv_for(command, args):
    section, name = command.split(":", 1)
    argv = [CLI, section, name]
    for key, value in args.items():
        argv += [f"--{key}", value]
    return argv


def run(command, args):
    try:
        proc = subprocess.run(argv_for(command, args) + ["--output", "json"], stdin=subprocess.DEVNULL,
                              capture_output=True, env=ENV, timeout=TIMEOUT, cwd="/")
    except subprocess.TimeoutExpired:
        return None
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return None


def registry_entry(command):
    result = run("self:commands", {})
    name = "simai-admin.sh " + command.replace(":", " ", 1)
    for entry in (result or {}).get("data", {}).get("commands", []):
        if entry.get("command") == name:
            return entry
    return {}


def plan(command, args):
    # Without --confirm only a command that requires confirmation is safe to call.
    if registry_entry(command).get("confirmation") != "required":
        return None
    result = run(command, args)
    if result is None or result.get("status") != "planned":
        return None
    entry = registry_entry(command)
    return {"command": command, "args": args, "target": result.get("target"),
            "description": entry.get("description"), "effects": result.get("effects"),
            "lock": entry.get("lock"), "applied": False}


# Jobs: a confirmed action runs as a transient systemd unit, so it survives
# the panel and the gateway call; its human output is the job log.
def job_dir(job_id):
    return JOBS / job_id


def unit_name(job_id):
    return f"simai-panel-job-{job_id}"


def prune_jobs():
    cutoff = time.time() - JOB_KEEP_DAYS * 86400
    for d in JOBS.glob("*"):
        if JOB_ID.match(d.name) and d.stat().st_mtime < cutoff and job_state(d.name)["state"] != "running":
            shutil.rmtree(d, ignore_errors=True)


def start_job(req, command, args):
    JOBS.mkdir(mode=0o700, parents=True, exist_ok=True)
    prune_jobs()
    job_id = secrets.token_hex(12)
    d = job_dir(job_id)
    d.mkdir(mode=0o700)
    meta = {"job_id": job_id, "request_id": req["request_id"], "actor": req["actor"], "command": command,
            "args": args, "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (d / "job.json").write_text(json.dumps(meta, ensure_ascii=False))
    script = d / "run.sh"
    quoted = " ".join("'" + a.replace("'", "'\\''") + "'" for a in argv_for(command, args) + ["--confirm", "yes"])
    # The arguments were validated against strict patterns; quoting keeps them literal.
    script.write_text(f"#!/bin/bash\n{quoted} </dev/null >{d}/log 2>&1\necho $? >{d}/exit_code\n")
    script.chmod(0o700)
    proc = subprocess.run(["systemd-run", f"--unit={unit_name(job_id)}", "--collect", "--quiet",
                           "--property=Type=exec", *(f"--setenv={k}={v}" for k, v in ENV.items()),
                           str(script)], capture_output=True, text=True, env=ENV, timeout=30)
    if proc.returncode != 0:
        (d / "exit_code").write_text("125\n")
        return job_id, False
    return job_id, True


def read_job(job_id):
    try:
        return json.loads((job_dir(job_id) / "job.json").read_text())
    except (OSError, ValueError):
        return None


def job_state(job_id):
    d = job_dir(job_id)
    meta = read_job(job_id) or {}
    code = None
    try:
        code = int((d / "exit_code").read_text().strip())
    except (OSError, ValueError):
        pass
    if (d / "cancelled").is_file():
        state = "cancelled"
    elif code is None:
        active = subprocess.run(["systemctl", "is-active", unit_name(job_id)], capture_output=True, text=True,
                                env=ENV, timeout=10).stdout.strip()
        state = "running" if active in ("active", "activating") else "failed"
    else:
        state = "succeeded" if code in (0, 88) else ("busy" if code == 75 else "failed")
    return {"job_id": job_id, "state": state, "exit_code": code, "command": meta.get("command"),
            "args": meta.get("args"), "created_at": meta.get("created_at"),
            "request_id": meta.get("request_id"), "actor": meta.get("actor")}


def job_visible(job_id, owner):
    meta = read_job(job_id)
    return meta is not None and (owner is None or (meta.get("actor") or {}).get("owner") == owner)


def job_answer(command, args, owner):
    if command == "job:list":
        jobs = [job_state(d.name) for d in sorted(JOBS.glob("*"), key=lambda p: p.stat().st_mtime, reverse=True)
                if JOB_ID.match(d.name) and job_visible(d.name, owner)][:100]
        return {"jobs": jobs}
    job_id = args["job_id"]
    if not job_visible(job_id, owner):
        raise Refused("unknown_job")
    if command == "job:status":
        return job_state(job_id)
    if command == "job:log":
        after = int(args.get("after", "0"))
        try:
            lines = (job_dir(job_id) / "log").read_text(errors="replace").splitlines()
        except OSError:
            lines = []
        chunk = lines[after:after + MAX_LOG_LINES]
        return {"job_id": job_id, "state": job_state(job_id)["state"], "lines": chunk, "next": after + len(chunk)}
    if job_state(job_id)["state"] != "running":
        raise Refused("not_running")
    (job_dir(job_id) / "cancelled").write_text(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n")
    subprocess.run(["systemctl", "stop", unit_name(job_id)], capture_output=True, env=ENV, timeout=60)
    return job_state(job_id)


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
        kind = ALLOW[command][2]
        if kind == "job":
            answer.update(status="ok", kind="result", data=job_answer(command, args, owner))
            raise Done
        if kind == "action":
            if not req.get("confirm", False):
                data = plan(command, args)
                if data is None:
                    answer.update(status="failed", reason="plan_failed")
                else:
                    answer.update(status="ok", kind="plan", data=data)
                raise Done
            job_id, started_ok = start_job(req, command, args)
            entry["job_id"] = job_id
            if started_ok:
                answer.update(status="ok", kind="job", job_id=job_id)
            else:
                answer.update(status="failed", reason="job_not_started", job_id=job_id)
            raise Done
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
    except Done:
        pass
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
