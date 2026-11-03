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
import hashlib
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
MAX_ATTACHMENT = int(os.environ.get("SIMAI_DEPLOY_MAX_ARCHIVE_MB", "1024")) * 1048576
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
PHP = re.compile(r"^[5-9]\.[0-9]$")
PROFILE = re.compile(r"^(static|generic|laravel|wordpress|node|redirect|proxy|bitrix)$")
ENGINE = re.compile(r"^(mysql|pgsql)$")
ORIGIN = re.compile(r"^https?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$")
CODE = re.compile(r"^30[1278]$")
KEEP_DROP = re.compile(r"^(keep|drop)$")
URL_PATH = re.compile(r"^/[A-Za-z0-9._~/%-]{0,500}$")
REDIRECT_TO = re.compile(r"^(/|https?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?/?)[A-Za-z0-9._~/%?&=+-]{0,500}$")
GIT_URL = re.compile(r"^(https://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?/[A-Za-z0-9._~/-]{1,300}|"
                     r"git@[A-Za-z0-9.-]{1,253}:[A-Za-z0-9._~/-]{1,300})$")
GIT_REF = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._/-]{0,199}$")
KEEP = re.compile(r"^(?:[1-9]|[1-4][0-9]|50)$")
PUBKEY = re.compile(r"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com) "
                    r"[A-Za-z0-9+/]{20,8192}={0,3}( [ -~]{0,200})?$")
SHA256 = re.compile(r"^[a-f0-9]{64}$")
BACKUP = re.compile(r"^[0-9]{8}-[0-9]{6}$")
CLOCK = re.compile(r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
KEEP_DAYS = re.compile(r"^(?:[1-9]|[1-8][0-9]|90)$")
MATCH = re.compile(r"^[ -~]{1,200}$")
ACCESS_LOGIN = re.compile(r"^(?!site-)[a-z][a-z0-9-]{2,31}$")
ALERT_ID = re.compile(r"^[a-f0-9]{12}$")
CHANNEL_KIND = re.compile(r"^(webhook|telegram|off)$")
CHANNEL_TARGET = re.compile(r"^(https?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~/%?&=+:@-]{0,500})?|"
                            r"-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})$")
TG_TOKEN = re.compile(r"^[0-9]{5,12}:[A-Za-z0-9_-]{30,64}$")
PHP_EXT = re.compile(r"^[a-z0-9_]{2,32}$")
SOFTWARE = re.compile(r"^(node|redis|postgresql)$")
MAJOR = re.compile(r"^[0-9]{2}$")
CF_TOKEN = re.compile(r"^[A-Za-z0-9_-]{30,64}$")
CHALLENGE = re.compile(r"^(http|dns)$")
DNS_PROVIDER = re.compile(r"^cloudflare$")
PERIOD = re.compile(r"^(day|week|month)$")
UPDATE_TARGET = re.compile(r"^(env|panel)$")
SERVICE = re.compile(r"^(nginx|mysql|mariadb|postgresql|redis-server|cron|php[5-9]\.[0-9]-fpm)$")
PORT = re.compile(r"^[1-9][0-9]{0,4}$")
UPSTREAM_PATH = re.compile(r"^/[A-Za-z0-9._~/-]{0,200}$")
BITRIX_FILES = re.compile(r"^(none|setup|restore)$")
CRON_ID = re.compile(r"^[a-f0-9]{8}$")
CRON_SCHEDULE = re.compile(r"^[0-9*/,-]{1,40}( [0-9*/,-]{1,40}){4}$")  # checked fully by the command
CRON_COMMAND = re.compile(r"^[!-,.-~][ -~]{0,999}$")
LIMIT = re.compile(r"^(?:[1-9]|[1-4][0-9]|50)$")
PROTO = re.compile(r"^(tcp|udp)$")
FW_ACTION = re.compile(r"^(allow|deny)$")
ADDRESS = re.compile(r"^[0-9A-Fa-f:.]{2,45}(/[0-9]{1,3})?$")  # checked fully by the command
FROM = re.compile(r"^(any|[0-9A-Fa-f:.]{2,45}(/[0-9]{1,3})?)$")
ADDRESSES = re.compile(r"^(any|[0-9A-Fa-f:./]{2,49}(,[0-9A-Fa-f:./]{2,49}){0,49})$")
RULE_ID = re.compile(r"^[a-f0-9]{8}$")
TTL = re.compile(r"^(?:0|[1-9][0-9]{1,7})$")
CHANGE_ID = re.compile(r"^[a-f0-9]{12}$")
INI_VALUE = re.compile(r"^[A-Za-z0-9_./+-]{1,64}$")
SIZE = r"^(?:[1-9][0-9]{0,3}M|[1-8]G)$"
SWITCH = r"^(?:on|off)$"
# Per-site PHP settings the panel may change, with their values. Anything
# else (open_basedir, disable_functions, extensions...) stays with the admin.
INI_RULES = {key: re.compile(rule) for key, rule in {
    "memory_limit": r"^(?:[1-9][0-9]{1,3}M|[1-8]G)$",
    "upload_max_filesize": SIZE,
    "post_max_size": SIZE,
    "max_execution_time": r"^(?:0|[1-9][0-9]{0,3})$",
    "max_input_time": r"^(?:-1|0|[1-9][0-9]{0,3})$",
    "max_input_vars": r"^[1-9][0-9]{2,5}$",
    "max_file_uploads": r"^[1-9][0-9]{0,3}$",
    "default_socket_timeout": r"^[1-9][0-9]{0,3}$",
    "session.gc_maxlifetime": r"^[1-9][0-9]{1,6}$",
    "output_buffering": r"^(?:on|off|[0-9]{1,6})$",
    "display_errors": SWITCH,
    "log_errors": SWITCH,
    "short_open_tag": SWITCH,
    "date.timezone": r"^(?:UTC|[A-Z][A-Za-z_]+(?:/[A-Z][A-Za-z0-9_+-]+){1,2})$",
}.items()}
INI_KEY = re.compile("^(?:" + "|".join(re.escape(k) for k in INI_RULES) + ")$")

# command -> (arguments with validators, required arguments, kind). Read
# commands answer structured, secret-free data (lib/command_contract.py);
# action commands answer a plan, and with confirm a job.
ALLOW = {
    "self:describe": ({}, set(), "read"),
    "self:commands": ({}, set(), "read"),
    "site:describe": ({"domain": DOMAIN}, {"domain"}, "read"),
    "site:doctor": ({"domain": DOMAIN, "strict": YES_NO, "include-target": YES_NO}, {"domain"}, "read"),
    "logs:nginx": ({"domain": DOMAIN, "kind": KIND, "lines": LINES, "match": MATCH}, {"domain"}, "read"),
    "ssl:letsencrypt": ({"domain": DOMAIN, "email": EMAIL, "redirect": YES_NO, "hsts": YES_NO, "staging": YES_NO,
                         "challenge": CHALLENGE, "wildcard": YES_NO}, {"domain", "email"}, "action"),
    "ssl:dns-credentials": ({"provider": DNS_PROVIDER, "token": CF_TOKEN, "remove": YES_NO}, {"provider"}, "action"),
    "ssl:dns-status": ({}, set(), "read"),
    "ssl:renew": ({"domain": DOMAIN}, {"domain"}, "action"),
    "site:deploy-rollback": ({"domain": DOMAIN}, {"domain"}, "action"),
    "backup:data": ({"domain": DOMAIN, "db": YES_NO, "files": YES_NO}, {"domain"}, "action"),
    "queue:restart": ({"domain": DOMAIN}, {"domain"}, "action"),
    "site:service-restart": ({"domain": DOMAIN}, {"domain"}, "action"),
    # Stage 3-4: deploys, creating and removing.
    "site:deploy": ({"domain": DOMAIN, "git": GIT_URL, "ref": GIT_REF, "migrate": YES_NO, "keep": KEEP},
                    {"domain"}, "action"),
    "site:add": ({"domain": DOMAIN, "profile": PROFILE, "php": PHP, "owner": OWNER, "create-db": YES_NO,
                  "db-engine": ENGINE, "redirect-to": ORIGIN, "redirect-code": CODE, "redirect-path": KEEP_DROP,
                  "backup": YES_NO, "upstream-port": PORT, "upstream-path": UPSTREAM_PATH, "websockets": YES_NO,
                  "bitrix-files": BITRIX_FILES},
                 {"domain", "profile"}, "action"),
    "site:remove": ({"domain": DOMAIN, "remove-files": YES_NO, "drop-db": YES_NO, "drop-db-user": YES_NO},
                    {"domain"}, "action"),
    "site:set-php": ({"domain": DOMAIN, "php": PHP}, {"domain", "php"}, "action"),
    "site:redirect-add": ({"domain": DOMAIN, "from": URL_PATH, "to": REDIRECT_TO, "code": CODE},
                          {"domain", "from", "to"}, "action"),
    "site:redirect-remove": ({"domain": DOMAIN, "from": URL_PATH}, {"domain", "from"}, "action"),
    "site:db-create": ({"domain": DOMAIN}, {"domain"}, "action"),
    "site:db-drop": ({"domain": DOMAIN}, {"domain"}, "action"),
    "cron:add": ({"domain": DOMAIN}, {"domain"}, "action"),
    "cron:remove": ({"domain": DOMAIN}, {"domain"}, "action"),
    "ssl:remove": ({"domain": DOMAIN, "delete-cert": YES_NO}, {"domain"}, "action"),
    "owner:create": ({"name": OWNER, "pubkey": PUBKEY}, {"name"}, "action"),
    "owner:add-key": ({"name": OWNER, "pubkey": PUBKEY}, {"name", "pubkey"}, "action"),
    "owner:remove": ({"name": OWNER}, {"name"}, "action"),
    "owner:block": ({"name": OWNER}, {"name"}, "action"),
    "owner:unblock": ({"name": OWNER}, {"name"}, "action"),
    # Stage 9: backups, PHP, metrics, databases.
    "backup:data-restore": ({"domain": DOMAIN, "backup": BACKUP, "db": YES_NO, "files": YES_NO},
                            {"domain", "backup"}, "action"),
    "backup:data-schedule": ({"domain": DOMAIN, "enabled": YES_NO, "time": CLOCK, "keep": KEEP_DAYS, "verify": YES_NO},
                             {"domain"}, "action"),
    "backup:data-verify": ({"domain": DOMAIN, "backup": BACKUP}, {"domain", "backup"}, "action"),
    "php:extensions": ({"php": PHP}, {"php"}, "read"),
    "php:list": ({}, set(), "read"),
    "php:install": ({"php": PHP, "include-common": YES_NO}, {"php"}, "action"),
    "php:remove": ({"php": PHP}, {"php"}, "action"),
    "php:extension": ({"php": PHP, "name": PHP_EXT, "enabled": YES_NO}, {"php", "name", "enabled"}, "action"),
    "php:update": ({"php": PHP}, {"php"}, "action"),
    "software:list": ({}, set(), "read"),
    "software:refresh": ({}, set(), "action"),
    "software:update": ({"security-only": YES_NO}, set(), "action"),
    "software:install": ({"name": SOFTWARE, "version": MAJOR}, {"name"}, "action"),
    "site:php-ini-list": ({"domain": DOMAIN}, {"domain"}, "read"),
    "site:php-ini-set": ({"domain": DOMAIN, "name": INI_KEY, "value": INI_VALUE}, {"domain", "name", "value"},
                         "action"),
    "site:php-ini-unset": ({"domain": DOMAIN, "name": INI_KEY}, {"domain", "name"}, "action"),
    "site:db-rotate": ({"domain": DOMAIN}, {"domain"}, "action"),
    "db:list": ({}, set(), "read"),
    "self:metrics": ({}, set(), "read"),
    # Stage 3.4: SFTP accounts of a site, key only: no password is ever set or shown.
    "access:list": ({"domain": DOMAIN}, set(), "read"),
    "access:create-project": ({"domain": DOMAIN, "login": ACCESS_LOGIN, "pubkey": PUBKEY},
                              {"domain", "login", "pubkey"}, "action"),
    "access:add-key": ({"login": ACCESS_LOGIN, "pubkey": PUBKEY}, {"login", "pubkey"}, "action"),
    "access:disable": ({"login": ACCESS_LOGIN}, {"login"}, "action"),
    "access:enable": ({"login": ACCESS_LOGIN}, {"login"}, "action"),
    "access:remove": ({"login": ACCESS_LOGIN}, {"login"}, "action"),
    # Stage 4 (1.31.0): server alerts that work while the panel is down, load history.
    "self:alerts": ({}, set(), "read"),
    "self:alerts-ack": ({"id": ALERT_ID}, {"id"}, "action"),
    "self:alerts-channel": ({"kind": CHANNEL_KIND, "target": CHANNEL_TARGET, "token": TG_TOKEN}, {"kind"}, "action"),
    "self:alerts-test": ({}, set(), "action"),
    "self:metrics-history": ({"period": PERIOD}, set(), "read"),
    # 1.32.0: safe update of simai-env or the panel build, with a plan first.
    "self:update-plan": ({"target": UPDATE_TARGET}, {"target"}, "read"),
    "self:update": ({"target": UPDATE_TARGET}, {"target"}, "action"),
    # 1.33.0: host services, site profiles for the wizard.
    "service:list": ({}, set(), "read"),
    "service:log": ({"name": SERVICE, "lines": LINES}, {"name"}, "read"),
    "service:restart": ({"name": SERVICE}, {"name"}, "action"),
    "service:reload": ({"name": SERVICE}, {"name"}, "action"),
    "self:profiles": ({}, set(), "read"),
    # 1.34.0: a site's own cron jobs, run as the site user.
    "cron:list": ({"domain": DOMAIN}, {"domain"}, "read"),
    "cron:job-add": ({"domain": DOMAIN, "schedule": CRON_SCHEDULE, "command": CRON_COMMAND},
                     {"domain", "schedule", "command"}, "action"),
    "cron:job-remove": ({"id": CRON_ID}, {"id"}, "action"),
    "cron:job-enable": ({"id": CRON_ID}, {"id"}, "action"),
    "cron:job-disable": ({"id": CRON_ID}, {"id"}, "action"),
    "cron:job-runs": ({"id": CRON_ID, "limit": LIMIT}, {"id"}, "read"),
    "firewall:status": ({}, set(), "read"),
    "firewall:rule-add": ({"port": PORT, "proto": PROTO, "from": FROM, "action": FW_ACTION}, {"port", "proto"}, "action"),
    "firewall:rule-remove": ({"id": RULE_ID}, {"id"}, "action"),
    "firewall:block": ({"address": ADDRESS, "ttl": TTL}, {"address"}, "action"),
    "firewall:unblock": ({"address": ADDRESS}, {"address"}, "action"),
    "panel:access": ({"allow": ADDRESSES}, {"allow"}, "action"),
    "change:confirm": ({"change_id": CHANGE_ID}, {"change_id"}, "action"),
    "change:status": ({"change_id": CHANGE_ID}, {"change_id"}, "read"),
    "job:status": ({"job_id": JOB_ID}, {"job_id"}, "job"),
    "job:log": ({"job_id": JOB_ID, "after": CURSOR}, {"job_id"}, "job"),
    "job:cancel": ({"job_id": JOB_ID}, {"job_id"}, "job"),
    "job:list": ({}, set(), "job"),
}
HOST_COMMANDS = {"self:describe"}  # owners get a filtered view
ADMIN_ONLY = {"owner:create", "owner:add-key", "owner:remove", "owner:block", "owner:unblock", "self:metrics",
              "self:alerts-channel", "self:alerts-test", "self:metrics-history", "self:update-plan", "self:update",
              "service:list", "service:log", "service:restart", "service:reload", "firewall:status",
              "firewall:rule-add", "firewall:rule-remove", "firewall:block", "firewall:unblock", "panel:access",
              "change:confirm", "change:status", "ssl:dns-credentials",
              "php:list", "php:install", "php:remove", "php:extension", "php:update",
              "software:list", "software:refresh", "software:update", "software:install"}
# Arguments the gateway always adds: the panel verifies with a restore test
# and applies PHP settings to the running pool.
FORCED = {"backup:data-verify": {"restore-test": "yes"}, "site:php-ini-set": {"apply": "yes"},
          "site:php-ini-unset": {"apply": "yes"}, "self:update": {"check-sites": "yes"}}
# Stopping these midway could leave the toolkit or the panel half replaced.
NO_CANCEL = {"self:update"}
CONDITIONAL = {"backup:data-verify"}  # a write (needs confirm) only with the forced arguments
BLOCKS = "/etc/simai-env/owner-blocks"  # a blocked owner's requests are refused
FILE_ARGS = {"pubkey": "pubkey-file", "token": "token-file"}  # passed to the command as a file
SECRET_ARGS = {"token"}  # never kept in a job record, and their file goes when the job ends
ALERTS = Path(os.environ.get("SIMAI_WATCH_DIR", "/var/lib/simai-env")) / "alerts.json"
ATTACHMENT = {"site:deploy"}  # may carry a release archive after the request line
ACCESS_DIR = Path(os.environ.get("SIMAI_ACCESS_DIR", "/etc/simai-env/access"))
BY_LOGIN = {"access:add-key", "access:disable", "access:enable", "access:remove"}  # scope from the account
BY_CRON_ID = {"cron:job-remove", "cron:job-enable", "cron:job-disable", "cron:job-runs"}  # scope from the job
RENAMED = {"change_id": "id"}  # the request name and the command's option
LIST_ARGS = {("panel:access", "allow")}  # may come as a JSON list; the command takes a comma list
CRON_JOBS = Path(os.environ.get("SIMAI_CRON_JOBS_DIR", "/etc/simai-env/cron-jobs"))


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
    for name, value in list(args.items()):
        if (command, name) in LIST_ARGS and isinstance(value, list):
            if not value or not all(isinstance(v, str) for v in value):
                raise Refused("invalid_argument")
            args[name] = value = ",".join(value)
        if name not in validators or not isinstance(value, str) or not validators[name].match(value):
            raise Refused("invalid_argument")
    if not required <= set(args):
        raise Refused("invalid_argument")
    confirm = req.get("confirm", False)
    if confirm not in (False, True) or (confirm and kind != "action"):
        raise Refused("not_allowed")  # only actions are confirmed
    attachment = req.get("attachment")
    if attachment is not None:
        if command not in ATTACHMENT or not isinstance(attachment, dict) or set(attachment) != {"sha256", "size"} \
                or not isinstance(attachment["sha256"], str) or not SHA256.match(attachment["sha256"]) \
                or not isinstance(attachment["size"], int) or isinstance(attachment["size"], bool) \
                or not 0 < attachment["size"] <= MAX_ATTACHMENT:
            raise Refused("invalid_argument")
        if "git" in args or "ref" in args:
            raise Refused("invalid_argument")  # an archive or a git ref, not both
    elif command in ATTACHMENT and "git" not in args:
        raise Refused("invalid_argument")
    if command == "site:deploy" and ("git" in args) != ("ref" in args):
        raise Refused("invalid_argument")
    if command == "site:php-ini-set" and not INI_RULES[args["name"]].match(args["value"]):
        raise Refused("invalid_argument")
    if owner is not None:
        if os.path.isfile(os.path.join(BLOCKS, owner)):
            raise Refused("owner_blocked")
        if command in ADMIN_ONLY:
            raise Refused("not_allowed")
        if command == "site:add":
            if args.get("owner", owner) != owner:
                raise Refused("owner_scope")
            args["owner"] = owner  # an owner's new site is always theirs
    if command == "self:alerts-ack":
        args["by"] = actor["user"]  # who acknowledged, as the panel knows them
    return req, command, args, owner


def argv_for(command, args, files=None):
    """Command line; file arguments become paths (placeholders for a plan)."""
    section, name = command.split(":", 1)
    argv = [CLI, section, name]
    for key, value in {**args, **FORCED.get(command, {})}.items():
        if key in FILE_ARGS:
            argv += [f"--{FILE_ARGS[key]}", (files or {}).get(key, "/dev/null")]
        else:
            argv += [f"--{RENAMED.get(key, key)}", value]
    for key, value in ((files or {}).get("attachment") or {}).items():
        argv += [f"--{key}", value]
    return argv


def run(command, args, files=None):
    try:
        proc = subprocess.run(argv_for(command, args, files) + ["--output", "json"], stdin=subprocess.DEVNULL,
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


def plan(command, args, attachment=None):
    # Without --confirm only a command that requires confirmation is safe to call.
    if command not in CONDITIONAL and registry_entry(command).get("confirmation") != "required":
        return None
    files = {"attachment": {"archive": "/dev/null", "sha256": attachment["sha256"]}} if attachment else None
    result = run(command, args, files)
    if result is None or result.get("status") != "planned":
        return None
    entry = registry_entry(command)
    shown = {k: ("(stored)" if k in SECRET_ARGS else v) for k, v in args.items()}
    answer = {"command": command, "args": shown, "target": result.get("target"),
              "description": entry.get("description"), "effects": result.get("effects"),
              "lock": entry.get("lock"), "applied": False}
    if command == "self:update":
        # Versions, release notes, what restarts and which sites are checked.
        answer["update"] = (run("self:update-plan", {"target": args["target"]}) or {}).get("data")
    elif command == "software:update":
        # The packages waiting in the apt index and whether a reboot is pending.
        answer["update"] = ((run("software:list", {}) or {}).get("data") or {}).get("system")
    return answer


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


def receive_attachment(path, attachment, stream):
    """Copy exactly `size` bytes from stdin and check their sha256."""
    digest, left = hashlib.sha256(), attachment["size"]
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as out:
        while left:
            chunk = stream.read(min(left, 1 << 20))
            if not chunk:
                break
            digest.update(chunk)
            out.write(chunk)
            left -= len(chunk)
    if left or stream.read(1) or digest.hexdigest() != attachment["sha256"]:
        path.unlink(missing_ok=True)
        raise Refused("attachment_mismatch")


def start_job(req, command, args, stream):
    JOBS.mkdir(mode=0o700, parents=True, exist_ok=True)
    prune_jobs()
    job_id = secrets.token_hex(12)
    d = job_dir(job_id)
    d.mkdir(mode=0o700)
    files, cleanup = {}, ""
    try:
        for key in FILE_ARGS:
            if key in args:
                fd = os.open(d / f"{key}.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "w") as out:
                    out.write(args[key] + "\n")
                files[key] = str(d / f"{key}.txt")
        if req.get("attachment"):
            archive = d / "release.tar.gz"
            receive_attachment(archive, req["attachment"], stream)
            files["attachment"] = {"archive": str(archive), "sha256": req["attachment"]["sha256"]}
            cleanup = f"rm -f {archive}\n"
    except Refused:
        shutil.rmtree(d, ignore_errors=True)
        raise
    for key in SECRET_ARGS:
        if key in files:
            cleanup += f"rm -f {files[key]}\n"
    shown = {k: ("(stored)" if k in SECRET_ARGS else v) for k, v in args.items()}
    meta = {"job_id": job_id, "request_id": req["request_id"], "actor": req["actor"], "command": command,
            "args": shown, "attachment": req.get("attachment"),
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (d / "job.json").write_text(json.dumps(meta, ensure_ascii=False))
    script = d / "run.sh"
    quoted = " ".join("'" + a.replace("'", "'\\''") + "'" for a in argv_for(command, args, files) + ["--confirm", "yes"])
    # The arguments were validated against strict patterns; quoting keeps them literal.
    # A command may leave a small result for the job (a timed change's id).
    script.write_text(f"#!/bin/bash\nexport SIMAI_JOB_RESULT={d}/result.json\n"
                      f"{quoted} </dev/null >{d}/log 2>&1\necho $? >{d}/exit_code\n{cleanup}")
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
    result = None
    try:
        result = json.loads((d / "result.json").read_text()[:4096])
    except (OSError, ValueError):
        pass
    return {"job_id": job_id, "state": state, "exit_code": code, "command": meta.get("command"),
            "args": meta.get("args"), "created_at": meta.get("created_at"),
            "request_id": meta.get("request_id"), "actor": meta.get("actor"),
            "result": result if isinstance(result, dict) else None}


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
    if (read_job(job_id) or {}).get("command") in NO_CANCEL:
        raise Refused("not_cancellable")
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


def owned_domains(owner):
    result = run("self:describe", {})
    return {s.get("domain") for s in (result or {}).get("data", {}).get("sites", []) if s.get("owner") == owner}


def owned(owner, domain):
    return domain in owned_domains(owner)


def load_alerts():
    try:
        return json.loads(ALERTS.read_text()).get("alerts", {})
    except (OSError, ValueError, AttributeError):
        return {}


def cron_domain(job_id):
    """The site a cron job belongs to, from root's job lists."""
    for f in CRON_JOBS.glob("*/jobs.json"):
        try:
            jobs = json.loads(f.read_text()).get("jobs", [])
        except (OSError, ValueError, AttributeError):
            continue
        if any(isinstance(j, dict) and j.get("id") == job_id for j in jobs):
            return f.parent.name
    return None


def access_domain(login):
    """Site of a project SFTP account, from its root-owned metadata; None for others."""
    try:
        lines = (ACCESS_DIR / f"{login}.env").read_text().splitlines()
    except OSError:
        raise Refused("unknown_access")
    meta = dict(line.split("=", 1) for line in lines if "=" in line)
    meta = {k: v.strip().strip('"') for k, v in meta.items()}
    return meta.get("DOMAIN") if meta.get("TYPE") == "project" else None


def allowed_commands(owner):
    return sorted(c for c in ALLOW if owner is None or c not in ADMIN_ONLY)


def log(entry):
    try:
        fd = os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a") as stream:
            stream.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def main():
    started = time.time()
    stream = sys.stdin.buffer
    raw = stream.readline(MAX_REQUEST + 1)  # the request line; an archive may follow
    answer = {"schema": "simai-panel-answer/1", "request_id": None}
    entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
             "caller": os.environ.get("SUDO_USER", "")}
    try:
        req, command, args, owner = parse(raw)
        answer["request_id"] = req["request_id"]
        entry.update(request_id=req["request_id"], user=req["actor"]["user"], owner=owner,
                     impersonated_by=req["actor"].get("impersonated_by"), command=command,
                     domain=args.get("domain"))
        if command not in ATTACHMENT or not req.get("confirm") or not req.get("attachment"):
            if stream.read(1):
                raise Refused("bad_request")  # nothing may follow a request without an archive
        if owner is not None and "domain" in args and command != "site:add" and not owned(owner, args["domain"]):
            raise Refused("owner_scope")
        if command in BY_LOGIN:
            domain = access_domain(args["login"])
            if domain is None:
                raise Refused("not_allowed")  # only a site's SFTP accounts, not global ones
            if owner is not None and not owned(owner, domain):
                raise Refused("owner_scope")
            entry["domain"] = domain
        if command in BY_CRON_ID:
            domain = cron_domain(args["id"])
            if domain is None:
                raise Refused("unknown_cron_job")
            if owner is not None and not owned(owner, domain):
                raise Refused("owner_scope")
            entry["domain"] = domain
        if command == "self:alerts-ack" and owner is not None:
            alert = load_alerts().get(args["id"])
            if alert is None:
                raise Refused("unknown_alert")
            if not alert.get("domain") or not owned(owner, alert["domain"]):
                raise Refused("owner_scope")  # host alerts are the administrator's
        kind = ALLOW[command][2]
        if kind == "job":
            answer.update(status="ok", kind="result", data=job_answer(command, args, owner))
            raise Done
        if kind == "action":
            if not req.get("confirm", False):
                data = plan(command, args, req.get("attachment"))
                if data is None:
                    answer.update(status="failed", reason="plan_failed")
                else:
                    answer.update(status="ok", kind="plan", data=data)
                raise Done
            job_id, started_ok = start_job(req, command, args, stream)
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
            if owner is not None and command == "self:alerts":
                mine = owned_domains(owner)
                data["alerts"] = [a for a in data.get("alerts", []) if a.get("domain") in mine]
                data.pop("channel", None)
            if owner is not None and command == "access:list":
                mine = owned_domains(owner)
                data["accesses"] = [a for a in data.get("accesses", []) if a.get("domain") in mine]
            if owner is not None and command == "db:list":
                mine = owned_domains(owner)
                data["databases"] = [d for d in data.get("databases", []) if d.get("site") in mine]
            if command == "self:describe":
                data["gate"] = {"commands": allowed_commands(owner)}  # what this panel user may call
            if command == "self:profiles":
                # Only the profiles site:add accepts here (no alias sites).
                data["profiles"] = [p for p in data.get("profiles", []) if PROFILE.match(p.get("id", ""))]
            if command == "site:php-ini-list":
                data["editable"] = sorted(INI_RULES)
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
