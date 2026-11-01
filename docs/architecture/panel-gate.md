# Panel gateway

Status: implemented in `admin/panel_gate.py`, `panel gate-enable|
gate-disable|gate-status`, test `panel_e2e`: stage 1 (read-only, 1.20.0),
stage 2 (certificates, backups and logs as data; plans and jobs, 1.21.0),
stages 3–4 (deploys with an uploaded archive or a git ref; creating and
removing sites, databases, redirects, owners, 1.22.0), stage 5 (`panel
install|remove|status|setup-link`, the placeholder, `install.sh` with the
panel, 1.23.0), stage 6 (the build installed through `site adopt` with a
health check, `panel update`, test `panel_install_e2e`, 1.25.0), stage 7 (the
published build pinned in `admin/panel-release.env`, `install.sh
--with-panel`, 1.26.0), stage 8 (site answers, disk and last backup in
the host description; `owner:block|unblock`, 1.27.0), stage 9 (restore,
verify and schedule backups, PHP settings and extensions, server metrics,
databases, a log filter, the command list in `self:describe`, 1.28.0),
stage 10 (a site's SFTP accounts by key, a check after each scheduled backup,
a daily backup for new sites, the last certificate renewal, 1.30.0), server
alerts and the load history (1.31.0).

## Installation

```bash
sudo /root/simai-env/simai-admin.sh panel install --domain panel.example.com --ssl-email ops@example.com --confirm yes
sudo /root/simai-env/simai-admin.sh panel update --confirm yes
# with the server:
bash install.sh --with-panel --panel-domain panel.example.com --panel-email ops@example.com
```

- The panel is an ordinary isolated site with its own account
  (`site-<project>`), never `simai` or root. Its domain must be new: an
  existing site is never taken over, and there is one panel per server.
- **Which build.** Without a source, the version and sha256 in
  `admin/panel-release.env`: each simai-env release pins one build from the
  GitHub releases of `simai/larena-env`, and the checksum in simai-env's own
  history is checked before anything is unpacked. `--version V --sha256 S`
  chooses another release; `--archive F --sha256 S` and `--git U --ref R` give
  a build directly.
- `--placeholder yes` installs `templates/panel-placeholder`, a generic PHP
  site that needs no download: it calls the gateway through
  `sudo -n /usr/local/sbin/simai-panel-gate` and shows only whether that works,
  because it has no sign-in. A build replaces it (it holds no data).
- The build is a Laravel site with a database. It is attached with `site adopt`, so it
  gets the requirements of its `.simai/app.json` and `composer.json`, its
  `.env` from `.env.example` (`APP_ENV=production`, `APP_DEBUG=false`,
  `APP_URL`), the database values, `APP_KEY`, migrations, workers and the
  scheduler; the same source is then deployed, so there is a release to roll
  back to. A build that does not answer its health path is not installed: the
  site, its files and its database are removed again.
- The panel site's account is added to the gateway's sudo file (next to
  `simai-panel` when `panel gate-enable` is on); `panel gate-disable` keeps
  the installed panel's access.
- **First sign-in.** The install writes `SIMAI_PANEL_SETUP_TOKEN=<64 hex>`
  into the site's shared `.env` and prints
  `https://<domain>/?setup=<token>` once, on stdout only (never in a log).
  The panel build accepts that link for the first administrator and then
  removes the line from `.env`. `panel setup-link` replaces the token (the
  old link stops working).
- `panel update` moves to the version pinned by the current simai-env release
  (`self update` does not update the panel by itself). It does nothing at that
  version and never steps back without `--version`; `--archive/--sha256` and
  `--git/--ref` work as for install. An update takes a `backup data` of the panel first, then an ordinary deploy, which
  migrates before the switch and keeps the current release when anything
  fails. A release that does not answer its health path is rolled back; the
  database is not, which is what the backup is for (`backup data-restore`).
  `.env`, the database and the storage directory survive an update.
- `panel remove` takes away the gateway access, then removes the panel site
  with its files and database; other sites are not touched. `panel status`
  shows domain, source, account, install time and release.

Larena Panel is a Larena application (package `larena/env`) installed by
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
| `refused` | not run; `reason`: `bad_request`, `too_large`, `bad_actor`, `not_allowed`, `invalid_argument`, `owner_scope`, `owner_blocked`, `attachment_mismatch`, `unknown_job`, `not_running` |
| `failed` | ran and failed; `reason`: the simai-env error code, `invalid_output`, `plan_failed` or `job_not_started` |

Secrets are never part of an answer: no `.env` values, database passwords,
private keys or deploy keys. Commands that print secrets for an operator
(for example a generated password) are not in the allowlist.

## Site data in the answers

Each site in `self:describe` and `site:describe` also carries:

- `answers`: `{http, path, checked_at}`, the HTTP status of the site's health
  path (`health.path` of `.simai/app.json`, else `/`) asked through nginx on
  127.0.0.1 without following redirects; `http` is `null` when nothing
  answered. `null` before the first check.
- `disk`: `{bytes, checked_at}`, the size of the site directory.
- `last_backup`: the time of the newest data backup, or `null`.

`answers` and `disk` come from `/var/lib/simai-env/site-status.json`, written
by `self status-refresh` from cron every five minutes (disk at most hourly),
so a description never waits for sites. Each owner in `isolation.owners` has
`blocked`, `blocked_at` and `sites_disk_bytes` (the sum of the owner's sites,
`null` while one is not measured yet).

`self:describe` also carries `gate.commands`: the commands this panel user
may call (an owner's list leaves out administrator commands). The panel shows
an action only when the server lists it.

`site:describe` (and each site in `self:describe`) carries `certificate`:
the names, issuer, `not_after`, `days_left`, `auto_renew` and `last_renew
{at, ok}` (the last renewal, `null` before the first) of the certificate nginx
serves, or `null`. Every site also has `last_verify {at, ok, backup,
restore_test}`, the last check of one of its backups, or `null`. `site:describe` also carries `backups`:
the daily schedule (`time`, `keep`, `dest`, `verify`), `last_verify` and every data backup directory
with `created_at`, `size_bytes`, `parts` (`db`, `files`, `config`),
`checksums` and `encrypted`. `logs:nginx {domain, kind: access|error,
lines: 1-1000, match}` answers `simai-log-tail/1` with the last lines; with
`match` (a fixed string, printable ASCII, up to 200 characters) the last
matching lines among the last 20000 lines of the file.

Stage 9 reads:

| Command | Answer |
| --- | --- |
| `self:metrics` | `simai-host-metrics/1`: `cpu {cores, load1, load5, load15}`, `memory` and `swap` `{total_bytes, used_bytes}`, `disk [{mount, total_bytes, used_bytes}]`, `checked_at`; administrator only |
| `php:extensions {php}` | `simai-php-extensions/1`: `extensions [{name, enabled}]`, from what PHP-FPM of that version loads and the packaged ones it does not |
| `site:php-ini-list {domain}` | `simai-php-ini/1`: `settings [{key, value, source: site}]`, the site's own settings, and `editable`: the keys the panel may set |
| `db:list` | `simai-databases/1`: `databases [{name, engine, site, size_bytes, users}]` of the sites; an owner gets only their sites' databases; no host, no passwords |
| `access:list {domain}` | `simai-access/1`: `accesses [{login, type, domain, enabled, auth, sftp_path, created_at}]`; an owner gets only their sites' accounts, never global ones; no passwords, no keys (stage 10) |

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

Stage 9 actions:

- `backup:data-restore {domain, backup, db, files}`: `backup` is a backup
  name (the last part of a `backups.items[].path`). The job verifies the
  backup, then backs up the current database as a new, ordinary backup (it
  shows in `backups` and can be restored the same way; nothing is pruned),
  then replaces the database. Files are extracted next to the site
  (`<root>.restore-<time>`) for review; the live files are not replaced.
- `backup:data-verify {domain, backup}`: checksums, archives and a restore
  test of the dump into a scratch database; the result is the job state and
  the `PASS` lines of `job:log`.
- `backup:data-schedule {domain, enabled, time, keep: 1-90}`. A manual
  `backup:data` keeps as many backups as the schedule does.
- `site:php-ini-set {domain, name, value}` and `site:php-ini-unset {domain,
  name}`: only the keys in `editable`, each with its own value rule (sizes
  like `256M`, seconds, `on|off`, a time zone); the setting is applied to the
  site's pool at once.
- `site:db-rotate {domain}`: a new database password, written only to the
  site's `.env` (which keeps its owner) and `db.env`; a cached Laravel config
  is rebuilt and workers restart. The password is never in an answer or a
  log. A database dump to keep is `backup:data {domain, files: no}`.

Stage 10 actions:

- `backup:data-schedule` takes `verify: yes|no`: after each successful
  scheduled backup the server checks that newest copy, with a restore test
  when it has a plain dump; the result is the site's `last_verify`.
- `site:add` takes `backup: yes|no`, default `yes`: the new site gets the
  daily backup at 03:30, keeping 7 (not for redirect sites).
- `access:create-project {domain, login, pubkey}`: an SFTP account for one
  site, chrooted to it (the site is `/site`), that logs in only with the key.
  No password is set, and `password` is not an argument. `access:add-key
  {login, pubkey}`, `access:disable`, `access:enable`, `access:remove
  {login}` work on a site's accounts only: the gateway finds the site from
  the account (`unknown_access` for an unknown login, `not_allowed` for a
  global account) and checks that an owner owns it (`owner_scope`).

Server alerts and load history (1.31.0). Kept by the server itself every five
minutes, also while the panel is closed or down (see `self alerts` in
docs/commands/self.md):

- `self:alerts` answers `simai-alerts/1`: `alerts [{id, kind, severity,
  domain, target, message, state: open|acked|resolved, first_seen,
  last_seen, acked_at, acked_by, resolved_at}]`, `checked_at` and `channel
  {kind, target_hint, last_sent_at, last_error}`. Kinds: `disk_full`,
  `cert_expiring`, `cert_renew_failed`, `site_down`, `panel_down`,
  `backup_missing`, `backup_failed`, `backup_check_failed`. An owner gets
  only alerts of their sites and no channel.
- `self:alerts-ack {id}` (action): the alert stays until its condition
  clears, marked as acknowledged by the panel user (`acked_by`). An owner
  may acknowledge only their sites' alerts (`owner_scope`, `unknown_alert`).
- `self:alerts-channel {kind: webhook|telegram|off, target, token}` and
  `self:alerts-test`, administrator only. `token` (the Telegram bot token)
  is passed as a file, shown as `(stored)` in plans and job records, and its
  file is removed when the job ends.
- `self:metrics-history {period: day|week|month}`, administrator only:
  `simai-metrics-history/1`, 5-minute points for a day, hourly for a week or
  a month, 30 days back.

Safe update (1.32.0), administrator only:

- `self:update-plan {target: env|panel}` answers `simai-update-plan/1`:
  `{target, current, available, update_available, blocked, notes [{version,
  text}], notes_url, backup, restarts, checks, rollback}`. For `env`,
  `available` comes from the update channel and `notes` are the CHANGELOG
  sections between the two versions; `checks` are the sites that answered
  in the last status run, `restarts` is empty (sites keep running). For
  `panel`, `available` is the build this simai-env release pins; `blocked`
  is `not_installed` or `placeholder` when there is nothing to update.
  `remote_unavailable` means the update channel did not answer.
- `self:update {target}` (action). Its plan carries the same data under
  `update`. The job, for `env`: notes which sites answer, replaces the
  toolkit (the updater keeps an archive of the previous one), runs host
  migrations, asks the sites again, and if a site that answered stops it
  puts the previous toolkit back and fails. Host migrations are not undone.
  For `panel`: a data backup of the panel, the deploy, a health check, and
  `site deploy-rollback` when the new release does not answer; the database
  is not rolled back. The job outlives the gateway itself being replaced;
  follow it with `job:status` and `job:log`. `job:cancel` answers
  `not_cancellable`: stopping midway could leave a half-replaced tree.

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
  pubkey}`, `owner:add-key`, `owner:remove`;
- stage 8 (1.27.0): `owner:block {name}`, `owner:unblock {name}`. Blocking
  expires the owner's account (SSH and SFTP stop, open sessions end) and
  refuses every request made as that owner (`owner_blocked`); the owner's
  sites keep serving;
- stage 9 (1.28.0): `backup:data-restore`, `backup:data-verify`,
  `backup:data-schedule`, `php:extensions`, `site:php-ini-list`,
  `site:php-ini-set`, `site:php-ini-unset`, `site:db-rotate`, `db:list`,
  `self:metrics` (administrator only), `logs:nginx` with `match`;
- stage 10 (1.30.0): `access:list`, `access:create-project`,
  `access:add-key`, `access:disable`, `access:enable`, `access:remove`;
  `backup:data-schedule` with `verify`; `site:add` with `backup`;
- 1.31.0: `self:alerts`, `self:alerts-ack`, `self:alerts-channel`,
  `self:alerts-test`, `self:metrics-history`;
- 1.32.0: `self:update-plan`, `self:update`.

Owner requests: `owner:*` is refused (`not_allowed`), and every request of a
blocked owner is refused (`owner_blocked`); `site:add` always
creates the site for the requesting owner (another `owner` is refused
`owner_scope`); every other domain must belong to the owner.

Interactive and operator-only commands (menus, `self bootstrap`,
`access reset-password`, `self ssh-hardening-ensure`, …) are never exposed.

## Recorded answers

`testing/fixtures/panel/` holds gateway answers recorded from the local
stand (`testing/stand/stand.sh record`): host description (also an owner's
view), command registry, `site describe` and `site doctor` for demo sites,
plans of the actions, the stage 9 reads, and refusals, one `owner_scope`
refusal per site action of stage 9, the SFTP account list and plans of stage
10, the alert list with one planted alert, the load history, and the update
plans (the remote version and notes of the `env` plan are pinned). Set 8
since 1.32.0. The panel's fixture driver replays them, and
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
