---
title: Panel gateway
description: How Larena Panel runs simai-env commands
---

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
alerts and the load history (1.31.0), the file manager with downloads
(1.39.0), uploads and archives (1.40.0).

## Installation

```bash
# a new server, one command; the panel answers on https://<server address>:8500
curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo bash -s -- --with-panel
# or at a domain that already points to the server
curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo bash -s -- --with-panel --panel-domain panel.example.com --panel-email ops@example.com
# on a server with simai-env
sudo /root/simai-env/simai-admin.sh panel install --confirm yes            # [--port 8500]
sudo /root/simai-env/simai-admin.sh panel install --domain panel.example.com --ssl-email ops@example.com --confirm yes
sudo /root/simai-env/simai-admin.sh panel update --confirm yes
```

The end of the output is what the person needs to start: the panel's
address and the one-time first sign-in link (see below).

### Where the panel answers (1.51.0)

- **By the server's address and port.** Every panel answers on
  `https://<server address>:<port>`, 8500 by default (`--port` on install,
  `--panel-port` for `install.sh`), with a self-signed certificate for the
  server's addresses (`/etc/simai-env/panel-tls`, 10 years). The browser
  warns once; the install prints the certificate's SHA-256 so the person can
  compare it. Plain HTTP sent to the port is redirected to HTTPS. The port is
  opened in ufw when ufw is on; a cloud provider's own firewall has to allow
  it too.
- **Without a domain** the panel site is called `panel.internal` (it never
  resolves) and its `APP_URL` is the address by IP.
- **A domain later.** `panel domain --domain D [--email E]` checks that `D`
  points to this server (`--check-dns no` skips it), serves the panel at
  `http://D`, asks Let's Encrypt for a certificate (HTTP-01 through the
  panel site's ACME location), and then serves `https://D` with HTTP
  redirected. `APP_URL` becomes `https://D`. While the address by IP is on,
  `https://D:<port>` answers too, with the domain's certificate (1.51.5).
  If no certificate comes, nothing
  is left of the domain. The certificate renews with the others
  (`ssl renew-due`). `panel domain --remove yes` takes it away again.
- **The panel's certificate and its session** (1.59.1). Whenever the
  panel's domain gets a certificate (`ssl letsencrypt`, `ssl install`, also
  from `panel install --email`) its `.env` gets `APP_URL=https://D` and
  `SESSION_SECURE_COOKIE=true`; without one (a new install, `ssl remove`)
  `http://D` and `false`; then `optimize:clear` runs as the panel's user.
  So a login over plain http works until the certificate comes instead of
  looping on a secure-only cookie.
- **Moving the port.** `panel port --port N` (100-65535, not SSH, web, mail
  or database ports, not in use) is a timed change: unless
  `change confirm --id <id>` comes within `--window` seconds (300 by default), the previous
  port comes back by itself, so a port the provider's network blocks does not
  lock anyone out. The old port is closed in ufw.
- **Only the domain.** `panel ip-access --enabled no` (timed as well) turns
  the address by IP off once the panel has a domain with a certificate.
- `panel address` (`--output json`: `simai-panel-address/1`) answers
  `{installed, site_domain, ip, addresses, port, ip_access, ip_url,
  ip_certificate {kind, sha256, expires}, domain, domain_ssl, domain_url,
  domain_managed, url}`; `url` is the address to use: the domain once it has
  a certificate, otherwise the address by IP.
- How: both addresses are copies of the panel site's own server block (root,
  PHP pool, access list, headers, locations) with other `listen` lines, in
  `/etc/nginx/conf.d/simai-panel-address.conf`, outside the site list.
  `self status-refresh` writes it again when the site's block changes;
  nginx must accept it or the previous file stays.
- Gateway, administrator only: `panel:address` (read), `panel:port {port}`,
  `panel:ip-access {enabled}` (timed: the job result has `change_id`, then
  `change:confirm` from the new address), `panel:domain {domain, email} |
  {remove: yes}`.

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
  into the site's shared `.env` and prints `<address>/?setup=<token>` once
  for each address of the panel (the domain and the address by IP), on
  stdout only (never in a log).
  The panel build accepts that link for the first administrator and then
  removes the line from `.env`. `panel setup-link` replaces the token (the
  old link stops working).
- **Password reset from the console** (1.63.3): `panel reset-password
  [--email <address>]` runs the build's `artisan larena:panel-reset-password
  [<email>]` as the panel account, with the panel's PHP, in `current`. It
  needs an interactive terminal (`ssh -t`): the new password is typed there
  twice, hidden, and never goes through arguments, the environment or the
  log. A non-zero exit (unknown or blocked account, refused password,
  cancelled input) is reported as "not reset". The panel shows this command
  on "Forgot password?" when mail is off.
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
- `lang` (1.60.0, optional): `ru` or `en` (the default). With `ru`, plan
  labels and values, job titles, step names, states and outcomes come in
  Russian from `lib/i18n/ru.json`; codes stay as they are. Any other value is
  refused `bad_request`.
- `actor.kind` (1.60.0, optional): `person` (the default), `schedule` or
  `server`, for the History page; anything else is refused `bad_actor`.

An action that carries a file sends it after the request line: the request
is one line ending in `\n` with
`"attachment": {"sha256": "<hex>", "size": <bytes>}`, followed by exactly that many bytes. Only `site:deploy` takes an
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
| `refused` | not run; `reason`: `bad_request`, `too_large`, `bad_actor`, `not_allowed`, `invalid_argument`, `owner_scope`, `owner_blocked`, `attachment_mismatch`, `unknown_job`, `not_running`; for site names `name_taken`, `name_is_primary`, `name_limit`, `name_unknown`; before `site:add` / `bitrix:restore-ready` `not_enough_disk`, `not_enough_ram`, `source_invalid`, `url_invalid` (with `data`: what the check found) |
| `failed` | ran and failed; `reason`: the simai-env error code, `invalid_output`, `plan_failed` or `job_not_started` |

Secrets are never part of an answer: no `.env` values, database passwords,
private keys or deploy keys. Commands that print secrets for an operator
(for example a generated password) are not in the allowlist.

### Several reads at once (1.52.0)

Each call costs the panel about 0.7-1 s on a small server, mostly simai-env
starting up, so a page that asks five things one after another waits about
five seconds. A batch asks them in one call and the gateway runs them side
by side, four at a time:

```json
{ "schema": "simai-panel-request/1", "request_id": "page-1", "actor": { … },
  "command": "batch",
  "requests": [ { "command": "self:describe" },
                { "command": "self:metrics-history", "args": { "period": "day" } } ] }
```

```json
{ "schema": "simai-panel-answer/1", "request_id": "page-1", "status": "ok",
  "kind": "batch", "answers": [ { "request_id": "page-1.0", "status": "ok", … },
                                { "request_id": "page-1.1", … } ] }
```

- 1 to 12 reads, kind `read` only; an action, a job look, a download or a
  nested batch is answered `refused`/`not_allowed` in its place, the others
  still run.
- Each read is checked, scoped to the owner and logged exactly as if it came
  alone, under the id `<request_id>.<index>`; `answers` keep the order of
  `requests`.
- A malformed batch (no list, more than 12, extra keys such as `confirm`, an
  id longer than 60) is refused as a whole with `bad_request`.
- Measured on 2 CPUs / 2 GB: five overview reads 4.3 s one by one, 2.6 s as a
  batch. The CPU is the limit, so a batch helps less on one core.

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
matching lines among the last 20000 lines of the file. Since 1.60.0
`lines` goes up to 10000 (a log download), `status` (`4xx,5xx`, `404`;
access log only) keeps the matching lines among the last 20000, and
`format: json` adds `entries [{at, level, status?, method?, path?, ip?,
message?, raw}]`: `at` is ISO 8601 with the zone (the access log's own; the
error log's local time with the server's zone).

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
registry entry requires confirmation are ever called this way; for the
others (since 1.49.0) the plan is a preview from the registry, marked
`preview: true`.

With `confirm: true` the gateway starts the command with `--confirm yes` as
a transient systemd unit `simai-panel-job-<job_id>` and answers
`kind: job`. The job survives the panel and the gateway call; its record,
human output and exit code are in `/var/lib/simai-env/panel-jobs/<job_id>/`
(root only, kept 30 days).

| Command | Answer |
| --- | --- |
| `job:status` `{job_id}` | `state`: `running`, `succeeded`, `failed`, `busy` (target locked), `cancelled`; exit code, command, arguments, actor; `result` when the command left one (values such as `wp:install`'s `admin_password` only in the first answer after the job ended); since 1.60.0 the job details below |
| `job:log` `{job_id, after}` | up to 1000 output lines after the cursor and `next`, for a live view |
| `job:cancel` `{job_id}` | stops the unit; refused `not_running` for a finished job |
| `job:list` `{before?, limit?, state?, since?}` | newest first, `limit` 1–100 (100 by default); `before=<job_id>` continues after that job ("More"); `state` a comma list (`running,failed`); `since` an ISO time `…Z`: jobs finished after it and every running one. Answer: `jobs`, `more`, `next_before`, and `counts {running, failed_since}` over all visible jobs, so a header indicator polls one small request |

### Job details (1.60.0)

Every `job:status` and `job:list` entry also has:

| Field | Meaning |
| --- | --- |
| `started_at`, `finished_at` | ISO 8601 in UTC (`2026-11-18T10:00:00Z`); `finished_at` is `null` while it runs |
| `title` | one phrase: `Копия сайта demo.test` (`lang: ru`), `Backup data demo.test` otherwise |
| `object` | `{kind, id}`: `site`, `owner`, `access`, `php`, `service`, `software`, `profile`, `panel`, `storage` or `server` |
| `actor.kind` | `person`, `schedule` or `server` (`person` when the panel did not say) |
| `state_words` | the state for people: `Выполняется`, `Готово`, `Ошибка`, `Отменено`, `Занято` |
| `steps` | `[{id, title, state, started_at?, finished_at?}]`, `state` `waiting`, `running`, `done` or `failed`; from the command's own progress lines (`[2/5] …`), the commands it runs are not mixed in; announced steps not reached yet are `waiting` with `title: null` |
| `progress` | `{current, total, title}`: "2 of 5: Создаётся база"; `null` for a command without steps |
| `outcome` | `{code, words, reason}` once it ended: `succeeded`, `failed`, `busy`, `cancelled`, `not_started` or `lost` (stopped without an exit code); for `failed`, `reason` is the command's last error line and `words` is `Ошибка: <reason>` |
| `cancel` | `{cancellable, leaves}`: whether `job:cancel` can stop it now and what stays done (the finished steps), or why it cannot (`self:update` is never stopped) |

### Plans in words (1.60.0)

A plan also carries `title`, `display` (`[{key, label, value, words}]`:
`create-db` → `Создать базу` / `да`, `locale` `en_US` → `английский`),
`effects_words` (`изменит настройки или файлы`, `удалит данные`),
`consequence` for commands that delete or replace data, and
`checks {blockers, notes}`: the plan check's errors (what would stop the
action: the domain points to another server, not enough disk, the site
exists) and warnings (worth knowing). A plan that fails answers
`failed`/`plan_failed` with `data.checks`; a refused plan (`not_enough_disk`
and the other plan refusals) has `data.checks` too.

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
  level: urgent|warning, title, line, domain, target, message, state:
  open|acked|resolved, first_seen, last_seen, acked_at, acked_by,
  resolved_at}]`, `checked_at` and `channel {kind, target_hint, levels,
  last_sent_at, last_error}`. `title` and `line` are Russian (1.63.0). A
  cleared alert stays the same record (same `id`) with `state: resolved`
  and `resolved_at` for 7 days. Kinds: `disk_full`,
  `cert_expiring`, `cert_renew_failed`, `site_down`, `panel_down`,
  `backup_missing`, `backup_failed`, `backup_check_failed`,
  `backup_offsite_failed`, `security_risk`. An owner gets
  only alerts of their sites and no channel.
- `self:alerts-ack {id}` (action): the alert stays until its condition
  clears, marked as acknowledged by the panel user (`acked_by`). An owner
  may acknowledge only their sites' alerts (`owner_scope`, `unknown_alert`).
- `self:alerts-channel {kind: webhook|telegram|off, target, token, levels:
  urgent|all}` (`levels` since 1.63.0, default `urgent`; with the current
  `kind` and no `target` only the levels change) and
  `self:alerts-test`, administrator only. `token` (the Telegram bot token)
  is passed as a file, shown as `(stored)` in plans and job records, and its
  file is removed when the job ends.
- `self:metrics-history {period: hour|6h|day|week|month}`, administrator
  only: `simai-metrics-history/1`, 1-minute points for an hour, 5-minute for
  6 hours or a day, hourly for a week or a month, 30 days back. Since 1.50.0
  every point also has `cpu_percent`, `net_rx_bytes_per_s`,
  `net_tx_bytes_per_s`, `disk_read_bytes_per_s`, `disk_write_bytes_per_s`
  (averages over the step, or `null`), and the answer has `host
  {net_interface, net_link_bits_per_s, disk_device, disk_kind}`
  (`docs/commands/self.md`).

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
  Since 1.42.1 the answer also carries codes for the panel to translate (the
  texts stay for older panels): `backup_item {kind: env_scripts|panel_data,
  path}` (null when nothing is backed up), `restart_items [{kind:
  php_fpm_pool|queue_workers|service, target}]` and `rollback_kind:
  env_release|panel_release`. For a panel installed from its own archive,
  `current` is the `version` of the build's `panel-build.json`.
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

Host services and site profiles (1.33.0):

- `service:list` (`simai-services/1`: `services [{name, active, enabled,
  since, can_reload}]`), `service:log {name, lines}` (`simai-service-log/1`:
  `{name, lines}`; since 1.60.0 `lines` up to 10000, `priority` (`err`,
  `warning`, …: that level and above) and `format: json` with `entries [{at,
  level, unit, message, raw}]` from journald, `at` with the zone),
  `service:restart {name}` and `service:reload {name}`
  (actions), administrator only; `service:stop` and `service:start` since
  1.62.0 (see the version list). `name` is one of `nginx`, `php<ver>-fpm`,
  `mysql`, `mariadb`, `postgresql`, `redis-server`, `cron`, and must exist on
  the host. nginx and PHP-FPM test their configuration first; a failed test
  fails the job and the service keeps running. A failed restart ends the job
  log with the unit's last journal lines.
- `self:profiles` (`simai-site-profiles/1`), for owners too: `php_installed`
  and `profiles [{id, title, php {versions, min, default} | null, db:
  no|optional|required, cron, queue, alias, args [{name, required, values |
  pattern, default, description}]}]`. Only the profiles `site:add` accepts
  through the gateway (no `alias`). Build the site wizard from it. Since
  1.57.5 the answer also carries `disabled [{id, title}]`: bundled profiles
  that are switched off. An administrator switches one with
  `profile:enable {id}` / `profile:disable {id}` (actions: a plan first,
  then a job; admin only). `profile:disable` refuses a core profile and a
  profile that sites still use; the job fails with the reason. Since
  1.56.0 each profile also carries `routes [{id: new|restore|repo, title,
  available, inputs [{name, required, kind, values?}], steps [{id, title,
  command, args | url_from}]}]` (docs/commands/self.md): every step is a
  gateway command or `open_url`, the last one `site:doctor`.
- `site:status {domain}` (1.56.0, read, `simai-site-status/1`): `route`,
  `step`, `next`, `restore_url`, `installer_url`, `pending`, `detail` for a
  site of any profile; `step` is a step id of the route, so the panel draws
  one step tracker for every profile (docs/commands/site.md).
- `site:add` takes `profile: proxy` with `upstream-port` (a service on
  127.0.0.1, not 80 or 443), `upstream-path`, `websockets: yes|no`, and
  `profile: bitrix` with `bitrix-files: none|setup|restore`. A profile the
  administrator has not enabled fails the job.

Site cron jobs (1.34.0):

- `cron:list {domain}` (`simai-cron-jobs/1`: `domain, jobs [{id, schedule,
  command, enabled, created_at, last_run {started_at, finished_at,
  exit_code} | null}]`), `cron:job-runs {id, limit}` (`simai-cron-runs/1`:
  `id, domain, runs [{started_at, finished_at, exit_code, output}]`, newest first,
  `output` holds the last 50 lines).
- `cron:job-add {domain, schedule, command}`, `cron:job-remove {id}`,
  `cron:job-enable {id}`, `cron:job-disable {id}` (actions). `schedule` is
  five cron fields, `command` one printable line up to 1000 characters that
  does not start with `-`. Jobs run as the site user in the site directory
  (`current/` for sites with releases); a run still going makes the next
  one skip. At most 50 jobs per site.
- Owners manage jobs of their own sites. A job id that does not exist is
  refused `unknown_cron_job`; a job of another owner's site `owner_scope`.

The file manager (1.39.0), for administrators and for owners on their own
sites (`owner_scope` otherwise). Everything runs as the site user inside the
site directory; links are never followed (`docs/commands/file.md`):

- Reads: `file:list {domain, path}` (`simai-files/1`), `file:stat {domain,
  path}` (`simai-file-stat/1`), `file:read {domain, path}` (`simai-file/1`
  with `sha256` and `content`, UTF-8 up to 1 MiB), `file:preview {domain,
  path, max-bytes?}` (1.61.0, `simai-file-preview/1`: an image whole as
  base64 or the start of a text file, `kind`, `mime`, `truncated`, `bytes`,
  `sha256`; up to 5 MiB).
- Actions:
  `file:write {domain, path, content, expect-sha256: <sha256>|new|any}` (the content travels in the request, so up to about 60 KB here; a
  job record keeps only its size, `"(N bytes)"`), `file:mkdir {domain,
  path}`, `file:rename {domain, path, to}`, `file:remove {domain, path}`.
  A failed write answers `changed` or `exists` in the job log.
- `file:upload {domain, path, expect-sha256: new|any|<sha256>}` (1.40.0)
  carries the file after the request line like `site:deploy`:
  `"attachment": {"sha256", "size"}`, then exactly `size` bytes, up to 1 GiB.
  It never replaces a file unless `expect-sha256` says so, and the job's copy
  is removed when the job ends.
- `file:archive {domain, path, to}` (`.zip`, `.tar.gz`, `.tgz`, `.tar`; links
  stored, never followed) and `file:extract {domain, path, to, overwrite}`
  (files and directories only; an entry leading outside refuses the whole
  archive) (1.40.0).
- `file:download {domain, path}`, a new answer kind: one answer line
  `{"status": "ok", "kind": "download", "data": {path, size, mtime}}`, then
  exactly `size` raw bytes, up to 1 GiB. A link, a directory or a missing
  path is refused (`not_a_file`, `not_found`, `too_large`) with the answer
  line only. If the file shrank while it was sent, fewer bytes follow; the
  panel compares the count with `size`.
- `path` is relative to the site directory: no `..`, no control
  characters, up to 1024 characters.

A site's own nginx directives (1.41.0), administrator only:

- `site:nginx-custom-show {domain}` (`simai-nginx-custom/1`: `domain, file,
  present, included, content, sha256, pending_change {change_id,
  expires_at}`).
- `site:nginx-custom {domain, content}` (empty content removes them): a timed
  change like `panel:access`. The job fails, with nothing changed, when nginx
  rejects the directives or the site stops answering; otherwise its `result`
  carries `change_id` and `expires_at`, and the change is undone after two
  minutes unless `change:confirm {change_id}` keeps it.

Apache mode (1.42.0), administrator only:

- `site:apache {domain, enable: yes|no}`: an action; the job fails, with
  nothing changed, when Apache rejects the configuration or the site stops
  answering. `site:describe` shows `web_server`.

Backup storages (1.44.0), administrator only:

- `backup:storage-list` (read, `simai-backup-storages/1`, no keys) and
  `backup:storage-copies {name, domain?}` (read, `simai-backup-copies/1`).
- `backup:storage-add {name, bucket, endpoint?, region?, prefix?, keep: 1-90,
  default?, access-key, secret-key}`: the keys go to the command as files,
  show as `(stored)` in the plan and the job, and their files are removed
  when the job ends. The job fails, with nothing saved, when the storage
  refuses the keys or the bucket.
- `backup:storage-test {name}`, `backup:storage-remove {name}` and
  `backup:storage-fetch {name, domain, backup}` (then `backup:data-restore`).
- Every `backup:data` (and scheduled backup) is uploaded to the default
  storage; `site:describe` shows `last_offsite`.

Security center (1.45.0), administrator only:

- `security:status` (read, `simai-security/1`, see docs/commands/security.md):
  score, problems with the most serious first, and for each a `fix` — a
  gateway command with its arguments that resolves it in one click — or a
  `how` text.
- `security:scan` (action): asks the vulnerability databases now.
- `security:fix {check: auto_updates|fail2ban|ssh_password}` (action with a
  plan); `ssh_password` is refused while no SSH key is set.
- `self:firewall-ensure` (action with a plan): turns on the firewall with
  SSH, HTTP and HTTPS open.
- New alert kind `security_risk` (target: the check id).
- 1.46.0: `security:files-scan {domain?}` (action), `security:files` (read,
  `simai-file-scan/1`), `security:quarantine {domain, path}` (action with a
  plan), `security:quarantine-list` (read, `simai-quarantine/1`),
  `security:quarantine-restore {id}` (action with a plan);
  `security:fix {check: antivirus}`.
- 1.47.0: `security:web-protect {enabled, rate: 2-1000, burst: 10-10000}` and
  `security:level {set: basic|enhanced|strict}` (actions with plans);
  `security:status` has `level {current, applied_at}` and the check
  `web_protect`.
- 1.48.0: `security:geo {mode: off|deny|allow, countries: "RU,KZ", ports:
  web|all, keep}` (action with a plan; `allow` and `ports: all` are timed
  changes: the job `result` has `change_id` and `expires_at`, confirmed with
  `change:confirm`), `security:geo-status` (read, `simai-geo/1`),
  `security:geo-update` (action), `security:geo-lookup {ip}` (read).
  `security:status` has `geo {mode, countries, ports}`.
- 1.49.0: `mcp:status` (read, `simai-mcp-status/1`), `mcp:enable`,
  `mcp:disable`, `mcp:key-add {pubkey, owner | admin: yes}`,
  `mcp:key-remove {fingerprint | owner}` (actions with plans): AI assistants
  over MCP, see `docs/commands/mcp.md`. MCP requests reach the gateway with
  the actor `mcp:<owner|admin>:<key>`.

Server software (1.38.0), administrator only:

- `software:list` (`simai-software/1`): `components [{name, package,
  installed, version, candidate, update, service, active, installable}]`
  (`node` also lists its `sites`), `system {updates, security, packages
  [{name, from, to, security}], kept_back, reboot_required, reboot_packages,
  index_age_seconds}`.
- Actions: `software:refresh` (the apt index), `software:update
  {security-only}` (its plan carries `update`: the `system` part of the
  list; the job fails and names sites that stopped answering or a rejected
  nginx or PHP-FPM configuration), `software:install {name: node|redis|
  postgresql, version}` (a Node.js major change is refused while node sites
  exist).
- Since 1.43.0 `software:list` is a catalogue of programs with `key, title,
  purpose, group, state, can_install, can_update, can_remove,
  install_blocked, remove_blocked, packages, php_extensions, keeps, sites`
  (see `docs/commands/software.md`). `software:install {name, version}`
  takes every installable key and updates an installed program;
  `software:remove {name}` is new. The plans of both carry `software`: the
  program's catalogue row, so the panel can say what is installed or
  removed, what is kept, and why the job would be refused.

PHP as software of the host (1.37.0), administrator only:

- `php:list` (`simai-php/1`): `native, versions [{version, fpm_active, sites,
  native, cli_default, package_version, updates, removable}], installable`.
- Actions: `php:install {php, include-common}`, `php:remove {php}` (fails
  while a site uses the version, and for the system and `php` command
  versions), `php:extension {php, name, enabled}` (turning on installs the
  package), `php:update {php}` (fixes within the version; the job fails and
  names sites that stopped answering). `php:extensions` stays a read for
  everyone.

DNS-01 certificates through Cloudflare (1.36.0):

- `ssl:dns-credentials {provider: cloudflare, token | remove: yes}`,
  administrator only. The token travels as a file like other secrets, is
  stored root-only on the host and is in no job record or log.
- `ssl:dns-status` (`simai-ssl-dns/1`): `providers [{provider, configured,
  updated_at, plugin_installed}]`, never the token.
- `ssl:letsencrypt` takes `challenge: http|dns` and `wildcard: yes|no`;
  `dns` uses the stored token, so a certificate can be issued before the
  domain points at the server. Without a stored token the job fails.

Firewall and panel access (1.35.0), administrator only:

- `firewall:status` (`simai-firewall/1`): `backend, active, default_incoming,
  ssh_ports, rules [{id, rule, action, port, proto, from, direction,
  protected}], blocks [{address, until, created_at}], panel_access {domain,
  allow: "any" | [addresses]} | null, pending_change {change_id, kind, domain,
  state, summary, created_at, expires_at} | null`.
- Actions: `firewall:rule-add {port, proto: tcp|udp, from: any|address|CIDR,
  action: allow|deny}`, `firewall:rule-remove {id}`, `firewall:block
  {address, ttl}` (seconds, 60-31536000; 0 or none: until unblocked),
  `firewall:unblock {address}`, `panel:access {allow}` (`"any"`, a list of
  addresses or CIDR blocks, or the same as a comma list; up to 50).
- Every one of them is a timed change. When its job succeeds, `job:status`
  carries `result: {change_id, kind: firewall|panel_access, expires_at}`.
  Unless `change:confirm {change_id}` comes before `expires_at` (120 s; the
  panel does not choose the window), the server puts the previous files back
  by itself. Send the confirm from the page that loaded over the new rules:
  a panel that locked itself out cannot confirm, and the change is undone.
  `change:status {change_id}` (`simai-change/1`: `state:
  pending|confirmed|restored`). Confirming an undone change fails the job.
- One change of a kind waits at a time: another one fails its job until the
  first is confirmed or undone. SSH ports, 80 and 443 cannot be denied for
  everyone, and their allow rules (`protected: true`) cannot be removed; such
  a job fails and nothing changes.
- Panel access always lets the host itself and certificate checks through.

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
  `site:names {domain}` (read, `simai-site-names/1`), `site:name-add {domain,
  name, mode: serve|redirect, check-dns}`, `site:name-remove {domain, name}`
  (1.53.0; details in docs/commands/site.md, "Extra names"). Before a plan
  or a job the gateway refuses `name_taken` (another site, one of its
  names, or the panel answers on it), `name_is_primary` (the site's main
  domain), `name_limit` (the site has 20 extra names; the main domain and
  wildcards are not counted, changing the mode of a listed name is) and,
  for removal, `name_unknown`. A name that does not point to the server or
  a certificate Let's Encrypt refuses fails the job; its log says why;
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
- 1.32.0: `self:update-plan`, `self:update`;
- 1.33.0: `service:list`, `service:log`, `service:restart`, `service:reload`,
  `self:profiles`; `site:add` with profiles `proxy` and `bitrix`;
- 1.34.0: `cron:list`, `cron:job-add`, `cron:job-remove`, `cron:job-enable`,
  `cron:job-disable`, `cron:job-runs`;
- 1.35.0: `firewall:status`, `firewall:rule-add`, `firewall:rule-remove`,
  `firewall:block`, `firewall:unblock`, `panel:access`, `change:confirm`,
  `change:status`; `job:status` with `result`;
- 1.36.0: `ssl:dns-credentials`, `ssl:dns-status`; `ssl:letsencrypt` with
  `challenge` and `wildcard`;
- 1.37.0: `php:list`, `php:install`, `php:remove`, `php:extension`,
  `php:update`;
- 1.38.0: `software:list`, `software:refresh`, `software:update`,
  `software:install`;
- 1.39.0: `file:list`, `file:stat`, `file:read`, `file:download`,
  `file:write`, `file:mkdir`, `file:rename`, `file:remove`;
- 1.40.0: `file:upload`, `file:archive`, `file:extract`;
- 1.41.0: `site:nginx-custom`, `site:nginx-custom-show`;
- 1.42.0: `site:apache`;
- 1.43.0: `software:remove`;
- 1.44.0: `backup:storage-list`, `backup:storage-add`, `backup:storage-test`,
  `backup:storage-remove`, `backup:storage-copies`, `backup:storage-fetch`;
- 1.45.0: `security:status`, `security:scan`, `security:fix`,
  `self:firewall-ensure`;
- 1.46.0: `security:files-scan`, `security:files`, `security:quarantine`,
  `security:quarantine-list`, `security:quarantine-restore`;
- 1.47.0: `security:web-protect`, `security:level`;
- 1.48.0: `security:geo`, `security:geo-status`, `security:geo-update`,
  `security:geo-lookup`;
- 1.51.0: `panel:address`, `panel:port`, `panel:ip-access`, `panel:domain`;
- 1.52.0: `batch` (several reads in one call);
- 1.53.0: `site:names`, `site:name-add`, `site:name-remove`;
- 1.55.0: `site:check-state {domain, id}` (read, `simai-site-check/1`),
  `site:check-fix {domain, id}`, `bitrix:status {domain}` (read,
  `simai-bitrix-status/1`), `bitrix:restore-ready {domain, archive}`,
  `bitrix:finalize {domain}`. `site:doctor` items of profile rules carry
  `key`, `fix` (a `site:check-fix` id or null), `since` (when the rule first
  failed, null while it passes) and `detail`; the answer names the
  `profile`. Before a `site:check-fix` plan or job the gateway refuses
  `unknown_check` (no such rule for the site's profile, or a rule without a
  fix) and `check_ok` (the rule holds); the plan carries `check` with
  `title` and `plan` (one line: what the button does). `site:add` of a
  profile switched off on the server is refused `profile_disabled`.
  `bitrix:status` answers `route` (setup|restore|installed|none), `step`
  (prepare|upload|validate|run_restore|run_setup|finalize|done), `next`
  (the command for the step, or `open_url`), `restore_url` /
  `installer_url` for the wizard steps and `pending` (rules `bitrix:finalize`
  will fix).
- 1.56.0: `laravel:finalize {domain, migrate}` (APP_KEY and the Laravel
  baseline after a panel deploy; `site:status` answers it as `next` of the
  `configure` step);
- 1.56.0: `site:status {domain}` (read, `simai-site-status/1`, the same
  keys for every profile); `self:profiles` answers `routes` per profile
  (`new`, `restore`, `repo` with inputs and steps). Fixture set 32 adds
  `site-status.<site>` for the demo sites and
  `site-status.demo-bitrix.test.<step>` along the Bitrix restore.
- 1.58.0: `site:db-browser {domain, minutes?}` (action; owners on their
  own sites; `minutes` 5 to 480, default 60) opens Adminer on the site's
  HTTPS address, signed in to the site's database only. The address is in
  the job result `browser_url` (with `expires_at`, `engine`, `database`),
  handed out once by `job:status` (ONCE_RESULT) and never in the job log;
  open it in a new tab. Plans refuse a site without its own database, PHP or
  HTTPS, an alias and a paused site (`plan_failed`).
  `site:db-browser-close {domain}` (action) and `site:db-browser-status
  {domain}` (read, `simai-db-browser/1`: `domain`, `open`, `expires_at`).
  `site:add` takes `ssl: yes|no`, `ssl-email` and `ssl-redirect: yes|no`:
  the site and its Let's Encrypt certificate in one job.
- 1.63.4: `site:restore-ready` names its refusal in the plan (`refused`
  with `reason` and `data.restore`): `site_missing`, `profile_bitrix`,
  `profile_wordpress`, `profile_unsupported`, `releases`, `root_missing`,
  `path_invalid`, `file_missing`, `symlink`, `not_file`, `files_is_dump`,
  `archive_kind`, `dump_kind`, `no_database`, `engine_unsupported`,
  `database_unreadable`, `database_not_empty`, `files_present`. Plans and
  refusals carry `restore` (`simai-site-restore-plan/1`: `root`, `doc_root`,
  `public_dir`, `files`, `dump`, `database {exists, engine, name, tables}`,
  `files_present`, `overwrite`, `backup`). `site:status` of a PHP site
  reports route `restore` once an archive or dump is in the site directory
  (or its web root): step `upload` (next `file:upload`) with a dump only,
  step `restore` (next `site:restore-ready`) with an archive; `detail` names
  `archive` and `dump`. A step title with no variables wins over a pattern
  that also fits it (the trash step no longer reads as a transfer).
- 1.64.0: `site:remove` (with `remove-files` or `drop-db`) and `site:db-drop`
  take a last backup first, held 7 days; a failed backup stops the job and
  its `reason` starts with `backup_failed`. `backup:data-list {domain?}`
  (read, admin-only, `simai-backup-list/1`) lists backups also of removed
  sites, with `reason` and `keep_until`. `file:write`, `file:upload` and
  `file:extract` keep the replaced file in the trash (`reason:
  overwritten`); the job result carries `previous_trash_id` or `trashed` and
  `trash_ids` (30 at most); `trash_failed` means nothing was replaced. The
  `file:trash-empty` plan carries `trash {items, bytes, ids}`.
- 1.65.1: `backup:data-list` items carry `profile`, `has_database`,
  `database`, `db_engine` (from the backup manifest; for `site:add` before
  a restore of a removed site). The preview link key is no longer in the
  nginx access log.
- 1.65.0: `site:preview-link {domain, minutes 10-1440}` (action; plan
  `preview {address, minutes, renew, mode}`; refusals `site_missing`,
  `alias`, `suspended`, `no_address`, `no_nginx`, `no_port`; the job result
  has `preview_url` once, plus `address`, `expires_at`, `mode`, `renewed`),
  `site:preview-link-close {domain}`, `site:preview-link-status {domain}`
  (read). `site:describe` has `preview_link`. `backup:data-restore` takes
  `files-live: yes|no`; its plan refuses `root_not_empty`,
  `no_files_archive`, `root_missing`, `releases`.
- 1.63.1: `owner:create {name, pubkey?, sites?}`: `sites` is a comma list
  (at most 50) of existing sites that move to the account in the same job.
  The plan has `owner {schema: simai-owner-create-plan/1, owner, new,
  sites [{domain, from}], per_site, on_failure}`; a plan or a confirmed
  request is refused `site_missing`, `alias`, `panel_site`,
  `owner_blocked`, `too_many` or `site_unsupported` before anything
  changes. Its title is "Новый аккаунт на сервере {name}". The
  `site:transfer` plan has `downtime` (none: PHP-FPM reloads gracefully).
- 1.63.0: alerts carry `level` (`urgent`, `warning`), a Russian `title`
  and `line`; `self:alerts-channel` takes `levels: urgent|all` (default
  `urgent`: only urgent alerts and their resolution are sent) and
  `channel.levels` is in `self:alerts`. Urgent security findings come as
  `security_risk` alerts (`critical` severity: `urgent`, `high`: `warning`).
- 1.62.2: files with passwords (`.env`, `wp-config.php`, `.settings.php`,
  `dbconn.php`, keys…; the list is in `docs/commands/file.md`) are
  `secret: true` in `file:list`, `file:stat` and `file:trash-list`.
  `file:archive` and `file:extract` take `without-secrets: yes|no`: such
  files are not packed, and are neither created nor overwritten on
  extraction; the job result has `secret_skipped [path]` (at most 30) and
  `secret_skipped_total`. Packing such a file itself fails (`secret`).
- 1.62.0: `service:stop {name}` and `service:start {name}` (actions,
  administrator only). `service:list` rows have `critical` and `can_stop`;
  a stop of nginx, PHP-FPM or a database server is refused `critical`
  before a job starts. The plan of a stop has `service {service, active,
  critical, server, sites [{domain, uses}], until}`: `uses` is
  `scheduler` (cron), `cache_store`, `cache_driver`, `session_driver`,
  `queue_connection` or `worker` (Redis); `server: true` for cron (the
  server's own checks pause).
- 1.61.0: `file:preview {domain, path, max-bytes?}` (read); the trash
  keeps 7 days and empties itself hourly; a `site:db-browser` plan is
  refused with its reason: `no_database`, `no_php`, `no_https`, `alias`
  (shares another site's PHP pool), `suspended`, `no_driver`,
  `engine_unsupported` (with `data.detail` and `data.checks`), before a job
  starts as well.
- 1.60.0: request `lang` and `actor.kind`; plans in words (`title`,
  `display`, `effects_words`, `consequence`, `checks {blockers, notes}`);
  job details (`started_at`, `finished_at`, `title`, `object`, `steps`,
  `progress`, `outcome`, `cancel`, `state_words`); `job:list {before, limit,
  state, since}` with `counts`; `logs:nginx` and `service:log` entries;
  `self:describe` has `timezone {name, offset}` and `panel {domain, version,
  pinned, source, installed_at, update_available}` (`null` without a
  panel): the panel updates with `self:update-plan` / `self:update`
  `target=panel`.
- 1.59.0: `site:db-credentials {domain}` (action; owners on their own
  sites): the job result carries `engine`, `host`, `port`, `database`,
  `user` and `db_password`, handed out once (ONCE_RESULT), never in the job
  log. `site:db-rotate` works on Bitrix and WordPress sites too: it rewrites
  the password in their PHP configuration; a configuration holding another
  password is refused in the plan (`plan_failed`). A database list for the
  panel is `db:list` (`simai-databases/1`: `databases [{name, engine, site,
  size_bytes, users}]`, owners see their sites'); a site without a database
  gets one with `site:db-create {domain}`.
- 1.57.1: `site:restore-ready {domain, files, dump?, overwrite?}` (action):
  a `generic` site from a files archive (`.tar.gz`, `.tgz`, `.tar`, `.zip`)
  and an optional MySQL dump inside the site directory; refusals of the
  plan check come as `plan_failed`. The `generic` profile's `restore` route
  is now available: `site:add`, `file:upload`, `site:restore-ready`,
  `site:doctor`, inputs `files` (required) and `dump` (optional).
  `wp:restore-ready` takes a `.zip` files archive too.
- 1.57.0: `site:redirect-list {domain}` (read, owner-scoped,
  `simai-site-redirects/1`): `redirects` `[{from, to, code}]` and
  `whole_domain` `{to, code, path}` or null. Fixtures
  `site-redirects.<site>`, `refused.owner-scope.site-redirects`.
- 1.56.2: the Laravel `repo` route lists `laravel:finalize` as its step
  after `site:deploy`. Memory needs are answered in the `resources` block of
  `site:add` plans, not in `self:profiles`; `available` is per route. Fixture
  set 33 adds `site-status.demo-wp.test.<step>`,
  `site-status.demo-wp-copy.test.<step>`,
  `site-status.demo-laravel.test.{deploy,configure}` and
  `plan.laravel-finalize`.
- 1.57.0: `site:suspend {domain}` and `site:resume {domain}` (actions with
  plans; owners on their own sites). A paused site answers `503` with
  `Retry-After` (the ACME challenge still works), its cron, cron jobs,
  workers and PHP-FPM pool are stopped; resume starts exactly what was
  stopped. `site:describe`, `self:describe` (per site) and `site:status`
  answer `suspended` (`describe` also `suspended_at`). Before a plan or a
  job the gateway refuses `already_suspended`, `not_suspended` and
  `panel_site` (the panel's own site). Stand fixtures `plan.site-suspend`
  and `refused.not-suspended`.

- 1.56.0: `bitrix:restore-ready {domain, archive, source, url}`: `source`
  is a path relative to the site directory (letters, digits, `._/-`, no
  `..`, no leading `/`) holding the volumes uploaded over SFTP; `url` an
  https address ending with the archive name (`.tar.gz`, `.tgz`, `.tar`,
  `.enc.gz`), with an optional query string; not both. The URL goes to the
  command as a file (`--url-file`, removed when the job ends), and plans
  and job records show it without its query string. `archive` also accepts
  `.enc.gz`. Plans of `site:add` and `bitrix:restore-ready` carry
  `resources` `{disk_free_bytes, needed_bytes, ram_mb, ram_min_mb,
  ram_recommended_mb, ok, refusal, warnings: [{code, message}]}`
  (warnings `ram_below_recommended`, `size_unknown`, `disk_unknown`);
  the `bitrix:restore-ready` plan also `archive` `{base, dir, source, url,
  volumes: [{name, size}], count, total_bytes, encrypted}` (null when
  nothing was found). Before a plan and again before a job the gateway
  refuses `not_enough_disk` (free disk on the docroot filesystem below
  three times the archive), `not_enough_ram` (memory below the profile's
  minimum), `source_invalid` (a link, a path outside the site directory or
  inside another site's, no or several archives) and `url_invalid` (a host
  that does not resolve to public addresses only); the refused answer
  carries `data` `{resources, archive, detail}`. The job log lists the
  volumes moved, their size, encryption and the SQL dump; `bitrix:status`
  then shows the step.
- 1.56.0: WordPress by one click. `wp:status {domain}` (read,
  `simai-wp-status/1`: `route` new|restore|installed|none, `step`
  prepare|upload|install|finalize|done, `next` (`wp:install`,
  `file:upload`, `wp:restore-ready`, `wp:finalize` or null), `url`,
  `pending` (rules `wp:finalize` will fix), `files` and `dumps` found in the
  site directory); `wp:install {domain, title, admin-user, admin-email,
  locale}` (a title may not start with `-`); `wp:restore-ready {domain,
  files, dump, overwrite}` (`files` and `dump` are paths in the site
  directory without `.`/`..` parts; the command refuses symlinks and other
  file types again); `wp:finalize {domain}`. Profile rules
  `wordpress.leftovers`, `wordpress.config-perms`, `wordpress.debug-off`,
  `wordpress.cron` work with `site:check-state` / `site:check-fix`.
  The admin password `wp:install` generates is delivered in the job result
  only. The job's human output (its log) says "in the job result"; the
  command writes `{admin_user, admin_password, login_url}` to the job's
  root-only `result.json`, and the first `job:status` of the finished job
  (succeeded or failed) returns it as `result`. That call moves the file
  away first, so only one caller gets it, and writes back the result
  without the password plus `shown_once: ["admin_password"]`; later
  `job:status` calls and `job:list` never carry it. A panel that misses the
  answer cannot ask again: the password is reset in WordPress ("Lost your
  password?") or with `wp user update`. Chosen over an `admin-password`
  argument so that no password is typed, sent to the gateway or kept in a
  job record at all.
- 1.57.0: `site:cache-clear {domain}` (action, any owner for their own
  sites): one site's caches and nothing of another site. The plan carries
  `clear`, a list of `{name, state, target, detail, reason}` with `name`
  `opcache` (this site's scripts, invalidated from inside its own PHP-FPM
  pool; never `opcache_reset()` or a reload, which would empty every pool
  of that PHP version), `nginx_cache` (the fastcgi/proxy cache zone the
  site's own config uses) and `framework` (Laravel `optimize:clear`,
  WordPress object cache and transients through WP-CLI, Bitrix
  `bitrix/cache`, `managed_cache`, `stack_cache`; as the site user), and
  `state` `planned` or `skipped` with `reason` (`none`: nothing of that
  kind is configured; `no_php`, `pool_socket_missing`, `zone_shared`,
  `zone_path_unknown`, `path_not_allowed`, `artisan_missing`,
  `wp_cli_missing`, `wordpress_not_installed`, `bitrix_missing`). The
  finished job's `result` is `simai-site-cache/1` `{domain, profile,
  applied, items}` with `state` `cleared|skipped|failed` and `detail`
  (counts). Alias, redirect and proxy sites are refused
  `profile_unsupported` before a plan and before a job, with `data.detail`.
- 1.57.0: the site trash and copy. `file:remove {domain, path}` now moves
  the path into the site's trash (`<site directory>/.simai-trash/`, the
  site user's, never served, kept across release rollbacks) instead of
  deleting it; the gateway never deletes for good (`permanent` is refused
  `invalid_argument`). `file:trash-list {domain}` (read,
  `simai-file-trash/1`: `dir, retention_days, entries [{id, path, name, type,
  size, deleted_at, expires_at}], count, total_bytes`),
  `file:trash-restore {domain, id, to}` (back where it was, or at `to`;
  missing parents are created), `file:trash-empty {domain, id}` (one entry,
  or all without `id`) and `file:copy {domain, path, to}` (links copied as
  links, never followed) are actions answered with plans. `id` is
  `YYYYMMDDTHHMMSSZ-` plus six hex characters, otherwise `invalid_argument`.
  The plans of `file:copy` and `file:trash-restore` fail (`plan_failed`)
  when the source or entry is missing or the target exists. Entries older
  than 7 days (30 before 1.61.0) are deleted by the next trash command of that site, and hourly by
  `self status-refresh`
  (`docs/commands/file.md`).
- 1.57.0: `site:transfer {domain, owner}` (action, administrator only like
  `owner:*`): the site moves to another owner (files, PHP-FPM pool, cron,
  workers, the owner's `~/sites` link; a `backup data` is taken first). The
  plan carries `transfer` `{schema: simai-site-transfer-plan/1, domain,
  from, from_owner, to_owner, backup, moves: [line]}`. Before a plan and
  again before a job the gateway refuses `owner_missing`, `owner_blocked`,
  `same_owner` (the site already belongs to that owner) and `panel_site`
  (the panel's own site).

Owner requests: `owner:*` and `site:transfer` are refused (`not_allowed`), and every request of a
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
plans (the remote version and notes of the `env` plan are pinned), the
service list and log, the site profiles, a site's cron jobs and runs with one
planted job, the firewall with one rule, one block and a confirmed change,
the DNS provider status with plans for a token and a DNS certificate, and
the PHP versions with plans for installing, removing and updating, and the
server software with plans for a system update and an install, and an
owner's site files with plans for a write, a removal, an archive and an
extraction (downloads and uploads are bytes and are not recorded), and a
site's own nginx directives with a plan to set them.
Set 17 since 1.41.0. The panel's fixture driver replays them, and
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
