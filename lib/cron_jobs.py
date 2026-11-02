#!/usr/bin/env python3
"""User cron jobs of a site: stored by root, run as the site user.

Usage (root only, called by admin/commands/cron.sh):
  cron_jobs.py list DOMAIN json|human
  cron_jobs.py add DOMAIN SCHEDULE COMMAND       prints the new id
  cron_jobs.py set ID enabled|disabled|removed
  cron_jobs.py domain ID                         prints the job's site
  cron_jobs.py runs ID LIMIT json|human
  cron_jobs.py render DOMAIN USER WORKDIR SLUG   writes /etc/cron.d/simai-jobs-SLUG
  cron_jobs.py purge DOMAIN SLUG                 forgets every job of a removed site

Jobs live in /etc/simai-env/cron-jobs/DOMAIN/jobs.json (root only); each
job's working directory and command go to ID.cmd there, readable by the site
user's group only, which the wrapper (lib/cron_job_run.sh) runs. Run records are written
by the wrapper as the site user to /var/lib/simai-env/cron-runs/DOMAIN/ID.jsonl.
"""
import json
import os
import pwd
import re
import secrets
import shutil
import sys
import tempfile
import time
from pathlib import Path

JOBS = Path(os.environ.get("SIMAI_CRON_JOBS_DIR", "/etc/simai-env/cron-jobs"))
RUNS = Path(os.environ.get("SIMAI_CRON_RUNS_DIR", "/var/lib/simai-env/cron-runs"))
CROND = Path(os.environ.get("SIMAI_CROND_DIR", "/etc/cron.d"))
WRAPPER = "/usr/local/lib/simai-env/cron-job-run"
MAX_JOBS = 50
ID = re.compile(r"^[a-f0-9]{8}$")
DOMAIN = re.compile(r"^[a-z0-9.-]{1,253}$")
RANGES = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]  # minute hour day month weekday


class Bad(Exception):
    pass


def schedule_ok(schedule):
    fields = schedule.split()
    if len(fields) != 5 or schedule != " ".join(fields):
        return False
    for field, (low, high) in zip(fields, RANGES):
        for part in field.split(","):
            m = re.fullmatch(r"(\*|(\d{1,2})(?:-(\d{1,2}))?)(?:/(\d{1,2}))?", part)
            if not m:
                return False
            start, end, step = m.group(2), m.group(3), m.group(4)
            if start is not None and not (low <= int(start) <= high):
                return False
            if end is not None and not (int(start) <= int(end) <= high):
                return False
            if step is not None and not 1 <= int(step) <= high:
                return False
    return True


def command_ok(command):
    return 0 < len(command) <= 1000 and command.isprintable() and not command.startswith("-") and command.strip() == command


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def site_dir(domain):
    if not DOMAIN.match(domain) or ".." in domain:
        raise Bad("invalid domain")
    return JOBS / domain


def load(domain):
    try:
        return json.loads((site_dir(domain) / "jobs.json").read_text()).get("jobs", [])
    except (OSError, ValueError, AttributeError):
        return []


def write_atomic(path, text, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp.")
    with os.fdopen(fd, "w") as out:
        out.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def save(domain, jobs):
    d = site_dir(domain)
    d.mkdir(mode=0o711, parents=True, exist_ok=True)
    os.chmod(d, 0o711)  # the site user opens its job files by name, cannot list
    write_atomic(d / "jobs.json", json.dumps({"schema": "simai-cron-jobs-state/1", "jobs": jobs}, indent=1), 0o600)


def find(job_id):
    if not ID.match(job_id):
        raise Bad("invalid id")
    for f in JOBS.glob("*/jobs.json"):
        domain = f.parent.name
        for job in load(domain):
            if job.get("id") == job_id:
                return domain, job
    raise Bad("unknown job")


def runs(domain, job_id, limit):
    try:
        lines = (RUNS / domain / f"{job_id}.jsonl").read_text(errors="replace").splitlines()
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict):
            out.append({"started_at": r.get("started_at"), "finished_at": r.get("finished_at"),
                        "exit_code": r.get("exit_code"), "output": [str(x)[:2000] for x in (r.get("output") or [])][-50:]})
        if len(out) >= limit:
            break
    return out


def cmd_list(domain, mode):
    jobs = []
    for job in load(domain):
        last = runs(domain, job["id"], 1)
        jobs.append({**job, "last_run": ({k: last[0][k] for k in ("started_at", "finished_at", "exit_code")}
                                         if last else None)})
    if mode == "json":
        print(json.dumps({"schema": "simai-cron-jobs/1", "domain": domain, "jobs": jobs}, ensure_ascii=False))
        return
    if not jobs:
        print(f"No cron jobs for {domain}")
    for j in jobs:
        last = j["last_run"]
        state = "on " if j["enabled"] else "off"
        print(f"{j['id']}  {state}  {j['schedule']:<16} {j['command']}"
              + (f"   (last: {last['started_at']} exit {last['exit_code']})" if last else ""))


def render(domain, user, workdir, slug):
    """The site's /etc/cron.d file and the command files the wrapper reads."""
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user) or not re.fullmatch(r"[a-z0-9-]{1,64}", slug):
        raise Bad("invalid user or slug")
    if not workdir.startswith("/") or "\n" in workdir:
        raise Bad("invalid workdir")
    try:
        gid = pwd.getpwnam(user).pw_gid
    except KeyError:
        raise Bad(f"unknown user {user}")
    jobs, d = load(domain), site_dir(domain)
    target = CROND / f"simai-jobs-{slug}"
    for f in d.glob("*.cmd") if d.is_dir() else []:
        if f.stem not in {j["id"] for j in jobs}:
            f.unlink()
    lines = []
    for job in jobs:
        # The command never appears in the cron line: % and quoting stay out of cron.
        write_atomic(d / f"{job['id']}.cmd", f"{workdir}\n{job['command']}\n", 0o640)
        os.chown(d / f"{job['id']}.cmd", 0, gid)
        if job.get("enabled"):
            lines.append(f"{job['schedule']} {user} {WRAPPER} {domain} {job['id']}")
    if not lines:
        target.unlink(missing_ok=True)
        return
    header = f"# simai-env user cron jobs of {domain}; managed by simai-admin.sh cron job-*, do not edit\n"
    write_atomic(target, header + "SHELL=/bin/bash\n" + "\n".join(lines) + "\n", 0o644)
    runs_dir = RUNS / domain
    runs_dir.mkdir(parents=True, exist_ok=True)
    # After site isolate the records and locks move to the new user too.
    for f in [runs_dir, *runs_dir.iterdir()]:
        if not f.is_symlink():
            os.chown(f, pwd.getpwnam(user).pw_uid, gid)
    os.chmod(runs_dir, 0o750)


def main(argv):
    action = argv[0] if argv else ""
    try:
        if action == "list":
            cmd_list(argv[1], argv[2])
        elif action == "add":
            domain, schedule, command = argv[1], argv[2], argv[3]
            if not schedule_ok(schedule):
                raise Bad("--schedule must be five cron fields, such as '*/5 * * * *'")
            if not command_ok(command):
                raise Bad("--command must be one line of printable text (up to 1000 characters)")
            jobs = load(domain)
            if len(jobs) >= MAX_JOBS:
                raise Bad(f"a site has at most {MAX_JOBS} cron jobs")
            job = {"id": secrets.token_hex(4), "schedule": schedule, "command": command, "enabled": True,
                   "created_at": now()}
            save(domain, jobs + [job])
            print(job["id"])
        elif action == "set":
            domain, job = find(argv[1])
            jobs = load(domain)
            if argv[2] == "removed":
                jobs = [j for j in jobs if j["id"] != job["id"]]
                (RUNS / domain / f"{job['id']}.jsonl").unlink(missing_ok=True)
            else:
                for j in jobs:
                    if j["id"] == job["id"]:
                        j["enabled"] = argv[2] == "enabled"
            save(domain, jobs)
            print(domain)
        elif action == "domain":
            print(find(argv[1])[0])
        elif action == "runs":
            domain, job = find(argv[1])
            data = {"schema": "simai-cron-runs/1", "id": job["id"], "domain": domain,
                    "runs": runs(domain, job["id"], int(argv[2]))}
            if argv[3] == "json":
                print(json.dumps(data, ensure_ascii=False))
            else:
                for r in data["runs"]:
                    print(f"{r['started_at']}  exit {r['exit_code']}")
                    for line in r["output"][-10:]:
                        print(f"    {line}")
        elif action == "render":
            render(*argv[1:5])
        elif action == "purge":
            shutil.rmtree(site_dir(argv[1]), ignore_errors=True)
            shutil.rmtree(RUNS / argv[1], ignore_errors=True)
            (CROND / f"simai-jobs-{argv[2]}").unlink(missing_ok=True)
        else:
            raise Bad("unknown action")
    except Bad as err:
        print(str(err), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
