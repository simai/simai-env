# Panel gateway

Status: implemented in `admin/panel_gate.py`, `panel gate-enable|
gate-disable|gate-status`, test `panel_e2e`: stage 1 (read-only, 1.20.0),
stage 2 (certificates, backups and logs as data; plans and jobs, 1.21.0),
stages 3–4 (deploys with an uploaded archive or a git ref; creating and
removing sites, databases, redirects, owners, 1.22.0), stage 5 (`panel
install|remove|status|setup-link`, the placeholder, `install.sh` with the
panel, 1.23.0).

## Installation

```bash
# placeholder now; the Larena build later replaces it
sudo /root/simai-env/simai-admin.sh panel install --domain panel.example.com --ssl-email ops@example.com --confirm yes
sudo /root/simai-env/simai-admin.sh panel install --domain panel.example.com --git <url> --ref <tag> --confirm yes
# or with the server: SIMAI_INSTALL_PANEL_DOMAIN=panel.example.com (and SIMAI_INSTALL_PANEL_EMAIL) for install.sh
```

- The panel is an ordinary isolated site with its own account
  (`site-<project>`), never `simai` or root. Its domain must be new: an
  existing site is never taken over, and there is one panel per server.
- Without a source the site gets the placeholder
  (`templates/panel-placeholder`, a generic PHP site): it calls the gateway
  through `sudo -n /usr/local/sbin/simai-panel-gate` and shows only whether
  that works, because it has no sign-in. With `--git/--ref` or
  `--archive/--sha256` the site is the Larena build: a Laravel site with a
  database; installing a build over the placeholder replaces it (the
  placeholder holds no data).
- The panel site's account is added to the gateway's sudo file (next to
  `simai-panel` when `panel gate-enable` is on); `panel gate-disable` keeps
  the installed panel's access.
- **First sign-in.** The install writes `SIMAI_PANEL_SETUP_TOKEN=<64 hex>`
  into the site's shared `.env` and prints
  `https://<domain>/?setup=<token>` once, on stdout only (never in a log).
  The panel build accepts that link for the first administrator and then
  removes the line from `.env`. `panel setup-link` replaces the token (the
  old link stops working).
- `panel remove` takes away the gateway access, then removes the panel site
  with its files and database; other sites are not touched. `panel status`
  shows domain, source, account, install time and release.

SIMAI ENV Panel is a Larena application (package `larena/env`) installed by
simai-env as an ordinary site. simai-env stays the only component that
changes the host; the panel asks it through one narrow entry point, the panel
gateway, modelled on the deploy gate (`admin/deploy_gate.sh`).

## Identity

- The panel's PHP-FPM pool runs as its own system account `simai-panel`, not
  `simai` (shared sites live there) and not root.
- `simai-panel` may run exactly one program as root, without arguments:
  `sudo -n /usr/local/sbin/simai-panel-gate` (written by
  `panel gate-enable`; it runs `python3 -I admin/panel_gate.py`).
- `panel gate-enable --pubkey-file K` also lets an SSH key reach the same
  gateway as a forced command (`restrict`, no TTY or forwarding): a panel on
  another machine, the laptop stand, or later several servers.
- The gateway reads one JSON request on stdin (at most 64 KiB) and writes one
  JSON answer on stdout. Each request is a JSON line in
  `/var/log/simai-panel-gate.log` (root only): request id, actor, owner,
  command, domain, status, reason and the simai-env `operation_id`, which
  links it to `/var/log/simai-admin.log`.

## Request

```json
{
  "schema": "simai-panel-request/1",
  "request_id": "01JB…",
  "actor": { "user": "admin@example.com", "owner": null, "impersonated_by": null },
  "command": "site:describe",
  "args": { "domain": "example.com" },
  "confirm": false
}
```

- `command` is a registry key (`section:name`) from `self commands`.
- `args` maps option names without `--` to strings; unknown options are
  refused before any handler runs.
- `actor.owner` is set when the panel user is an owner (or an administrator
  acting as one): the gateway then refuses any `domain` that the owner does
  not own, and any host-level command.
- `confirm: false` on a state-changing command returns the plan only, as the
  CLI does without `--confirm yes`.

An action that carries a file sends it after the request line: the request
is one line ending in `\n` with `"attachment": {"sha256": "<hex>", "size":
<bytes>}`, followed by exactly that many bytes. Only `site:deploy` takes an
attachment (a release `tar.gz`, at most `SIMAI_DEPLOY_MAX_ARCHIVE_MB`, 1024
MB by default), and only with `confirm: true`; a plan needs the metadata
only. A wrong size or digest is refused `attachment_mismatch`; bytes after a
request without an attachment are refused `bad_request`. Public SSH keys
travel as text (`"pubkey": "ssh-ed25519 AAAA… comment"`) and reach the
command as a file.

## Answer

```json
{ "schema": "simai-panel-answer/1", "request_id": "01JB…", "status": "ok",
  "kind": "result", "data": { … }, "command_status": "success",
  "operation_id": "20261028195030885137839" }
```

`data` is the command's own structured answer (`self describe`,
`site describe`, …; see `testing/fixtures/panel/`). `command_status` is the
simai-env result status: `site doctor` answers `ok` with
`command_status: failed` when a diagnostic check fails.

| `status` | Meaning |
| --- | --- |
| `ok` | `kind` is `result` (data), `plan` (what an action would do) or `job` (`job_id` of a started action) |
| `refused` | not run; `reason`: `bad_request`, `too_large`, `bad_actor`, `not_allowed`, `invalid_argument`, `owner_scope`, `attachment_mismatch`, `unknown_job`, `not_running` |
| `failed` | ran and failed; `reason`: the simai-env error code, `invalid_output`, `plan_failed` or `job_not_started` |

Secrets are never part of an answer: no `.env` values, database passwords,
private keys or deploy keys. Commands that print secrets for an operator
(for example a generated password) are not in the allowlist.

## Site data in the answers

`site:describe` (and each site in `self:describe`) carries `certificate`:
the names, issuer, `not_after`, `days_left` and `auto_renew` of the
certificate nginx serves, or `null`. `site:describe` also carries `backups`:
the daily schedule (`time`, `keep`, `dest`) and every data backup directory
with `created_at`, `size_bytes`, `parts` (`db`, `files`, `config`),
`checksums` and `encrypted`. `logs:nginx {domain, kind: access|error,
lines: 1-1000}` answers `simai-log-tail/1` with the last lines.

## Actions and jobs

An action without `confirm` answers `kind: plan`: command, arguments, target,
description, effects and lock. Nothing runs, and only commands whose
registry entry requires confirmation are ever called this way.

With `confirm: true` the gateway starts the command with `--confirm yes` as
a transient systemd unit `simai-panel-job-<job_id>` and answers
`kind: job`. The job survives the panel and the gateway call; its record,
human output and exit code are in `/var/lib/simai-env/panel-jobs/<job_id>/`
(root only, kept 30 days).

| Command | Answer |
| --- | --- |
| `job:status` `{job_id}` | `state`: `running`, `succeeded`, `failed`, `busy` (target locked), `cancelled`; exit code, command, arguments, actor |
| `job:log` `{job_id, after}` | up to 1000 output lines after the cursor and `next`, for a live view |
| `job:cancel` `{job_id}` | stops the unit; refused `not_running` for a finished job |
| `job:list` | the last 100 jobs |

An owner sees and controls only jobs started as that owner.

## Allowlist

The allowlist is the `ALLOW` table in `admin/panel_gate.py`: each command
with a validator per argument, its required arguments and its kind (read,
action, job). Everything else is refused.

- stage 1 (1.20.0): `self:describe`, `self:commands`,
  `site:describe {domain}`, `site:doctor {domain, strict, include-target}`.
  An owner gets `self:describe` reduced to their own sites and is refused
  (`owner_scope`) on any other domain. `confirm` is refused on reads;
- stage 2 (1.21.0): `logs:nginx`; actions `ssl:letsencrypt {domain, email,
  redirect, hsts, staging}`, `ssl:renew`, `site:deploy-rollback`,
  `backup:data {domain, db, files}` (`db: no` for a site without a
  database), `queue:restart`, `site:service-restart`; `job:*`;
- stages 3–4 (1.22.0): `site:deploy {domain, git, ref, migrate, keep}` or
  with an attachment; `site:add {domain, profile, php, owner, create-db,
  db-engine, redirect-to, redirect-code, redirect-path}`; `site:remove
  {domain, remove-files, drop-db, drop-db-user}`; `site:set-php`;
  `site:redirect-add {domain, from, to, code}`, `site:redirect-remove`;
  `site:db-create`, `site:db-drop`; `cron:add`, `cron:remove` (the Laravel
  scheduler entry); `ssl:remove {domain, delete-cert}`; `owner:create {name,
  pubkey}`, `owner:add-key`, `owner:remove`.

Owner requests: `owner:*` is refused (`not_allowed`); `site:add` always
creates the site for the requesting owner (another `owner` is refused
`owner_scope`); every other domain must belong to the owner.

Interactive and operator-only commands (menus, `self bootstrap`,
`access reset-password`, `self ssh-hardening-ensure`, …) are never exposed.

## Recorded answers

`testing/fixtures/panel/` holds gateway answers recorded from the local
stand (`testing/stand/stand.sh record`): host description (also an owner's
view), command registry, `site describe` and `site doctor` for demo sites,
and two refusals. The panel's fixture driver replays them, and
both sides test against the same files: simai-env checks that it still
answers in this shape, `larena/env` checks that it can display it. Re-record
after a change of the answer shape, never edit the files by hand.

## Local development

`testing/stand/stand.sh up` starts a long-lived Ubuntu container with
simai-env and demo sites (static, PHP with a database, an owner's site, a
redirect) on `127.0.0.1:18080`, and enables the gateway for the key
`~/.simai-stand/panel_ed25519`. The panel can run on the laptop with the
fixture driver, and switch to the stand with the same requests:

```bash
printf '%s' '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"me","owner":null},"command":"self:describe","args":{}}' \
  | ssh -i ~/.simai-stand/panel_ed25519 -p 12222 simai-panel@127.0.0.1
```
