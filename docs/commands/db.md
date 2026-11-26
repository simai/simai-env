# Database commands

Manage MySQL databases and users for individual sites. Credentials are stored at `/etc/simai-env/sites/<domain>/db.env` (mode 0640, root owned); passwords are never logged.

## Global database status

### db status
`simai-admin.sh db status`

Shows:
- mysql service state
- whether mysql is enabled
- detected version
- socket presence
- port
- datadir
- free disk near the datadir
- ping/query reachability

This is the command used by the normal `Database -> Database server status` menu item.

### db list
`simai-admin.sh db list`

Lists databases currently visible through MySQL root access.

This is the command used by the normal `Database -> List databases` menu item.

Notes:
- It is read-only.
- It does not print users, grants, or passwords.
- Output is intended as a quick operational overview, not a schema dump.

## Per-site database actions

## db-status
`simai-admin.sh site db-status --domain <domain>`
- Shows db.env presence, DB name/user/host/charset/collation (without password), and existence of DB/user/grants.

## db-create
`simai-admin.sh site db-create --domain <domain> [--dry_run yes] [--confirm yes]`
- Profile-aware defaults for charset/collation/privileges; refuses when profile declares no DB.
- Dry-run prints the plan only. Real execution requires `--confirm yes` in CLI (menu asks interactively).
- Creates or reuses the managed DB + user for the site, repairs grants when needed, then writes db.env.

## db-drop
`simai-admin.sh site db-drop --domain <domain> [--dry_run yes] [--confirm yes] [--remove_files yes]`
- Dry-run prints what would be dropped. Real execution requires confirmation.
- Drops DB and user; removes db.env only when `--remove_files yes`.
- First (1.64.0) a last backup of the database, kept 7 days (`reason=db-drop`,
  see `backup data-list`); if it fails, nothing is dropped and the error
  starts with `backup_failed`. `--last-backup no` (console only) skips it.
  To restore: `site db-create`, then `backup data-restore --backup <timestamp> --files no`.

## db-rotate
`simai-admin.sh site db-rotate --domain <domain> [--dry_run yes] [--confirm yes]`
- Rotates the DB user password and updates db.env; the new password is not
  printed (`site db-credentials` shows it).
- Laravel and other `.env` sites: the project `.env` is updated (in menu mode
  it asks first), then the config cache is rebuilt and workers restart.
- Bitrix and WordPress (1.59.0): the password is also replaced in
  `bitrix/.settings.php` and `bitrix/php_interface/dbconn.php`
  (`$DBPassword`), or in `wp-config.php` (`DB_PASSWORD`; the web root or its
  parent). Only a value equal to the old db.env password is replaced, as
  the file's owner; other `password` keys (a cache server) stay. A file that
  holds another password is refused already in the plan, and nothing
  changes. If a file cannot be written, the old password is restored.

## db-credentials
`simai-admin.sh site db-credentials --domain <domain> --confirm yes`
- Shows the connection details of the site's database (1.59.0): engine,
  host, port, database, user and password, for another application or a
  desktop client (over an SSH tunnel). Without `--confirm yes` it prints a
  plan.
- Panel gateway: `site:db-credentials {domain}` (action; owners on their own
  sites). The job result carries `engine`, `host`, `port`, `database`,
  `user` and `db_password`; `job:status` hands `db_password` out once, and
  neither the job log nor the admin log contains it.

## db-extra-add / db-extra-drop / db-extra-list (1.70.0)
```bash
sudo /root/simai-env/simai-admin.sh site db-extra-add --domain D --name logs                 # plan
sudo /root/simai-env/simai-admin.sh site db-extra-add --domain D --name logs --confirm yes
sudo /root/simai-env/simai-admin.sh site db-extra-list --domain D --output json
sudo /root/simai-env/simai-admin.sh site db-extra-drop --domain D --name logs --confirm yes   # [--last-backup no]
```
- A site may have extra databases next to its main one: `<main db>_<name>`
  (`--name`: 1-16 of `a-z`, `0-9`, `_`) on the site's engine. The site's own
  database user gets them (MySQL grants of the profile, PostgreSQL owner;
  `PUBLIC` cannot connect): no other user, no other password.
- Refused, already in the plan: a bad name (`name_invalid`), a name the site
  already has (`name_taken`), a full name over the engine's limit (MySQL 64,
  PostgreSQL 63 characters: `name_too_long`), a database of that name that
  exists on the server but is not the site's (`database_exists`), a site
  without a database (`no_database`, `profile_no_database`); drop of a name
  the site does not have: `name_unknown`.
- `db.env` records the names as `DB_EXTRA=logs,cache` (not a secret; kept
  by `site db-rotate`).
- `db-extra-drop` first takes a last backup of the site's databases, kept 7
  days (`reason=db-extra-drop`), like `site db-drop`; `--last-backup no`
  (console only) skips it. The main database and its user stay.
- `site db-drop` and `site remove --drop-db yes` drop the extras too.
- `backup data` dumps each extra database to `db-extra-<name>.sql.gz`
  (listed as `db_extra=` in `manifest.txt`; `backup data-list` shows
  `extra_databases`), `backup data-verify` checks them (with
  `--restore-test yes` each is imported into a scratch database), and
  `backup data-restore` restores them into `<main db>_<name>`, creating a
  missing one for the site's user. Backups without extras verify and restore
  as before.
- `site describe` / `self describe` (`database.extra`), `site db-status`,
  `site db-credentials` (`extra_databases` in the panel job result) and
  `db list --output json` (`kind: extra`) show the names, never a password.
- Panel gateway: `site:db-extra-add {domain, name}`,
  `site:db-extra-drop {domain, name}` (actions), `site:db-extra-list {domain}`
  (read, `simai-db-extra/1`).

## db-export
`simai-admin.sh site db-export --domain <domain> [--target .env] [--confirm yes]`
- Writes DB_HOST/DB_DATABASE/DB_USERNAME/DB_PASSWORD into the target file under the project directory (default `.env`), idempotently updating keys.
- Requires confirmation in CLI; menu asks interactively. Password is not logged.

Notes:
- Commands use MySQL root via socket auth; no passwords are logged.
- CLI requires explicit confirmation for destructive/creating actions; menu always asks.
- db.env under `/etc/simai-env/sites/<domain>/` is the source of truth; export to project envs is a separate, idempotent step.

## Legacy db commands
Legacy commands (`db create/drop/set-pass`) remain for backward compatibility but are deprecated. Prefer the site-scoped commands (`site db-create/db-drop/db-rotate/db-export`) which handle profile defaults, safe storage, and better confirmations.


## PostgreSQL

```bash
sudo /root/simai-env/simai-admin.sh db pgsql-install --confirm yes                   # Ubuntu version (14 on 22.04, 16 on 24.04, 18 on 26.04)
sudo /root/simai-env/simai-admin.sh db pgsql-install --version 17 --pgdg yes --confirm yes
sudo /root/simai-env/simai-admin.sh db pgsql-status
sudo /root/simai-env/simai-admin.sh site add --domain D --profile laravel --create-db yes --db-engine pgsql
```

Versions outside the Ubuntu repository come from the PGDG repository with a
fingerprint-pinned key (`signed-by`). The server listens on localhost. Each
site gets a role that owns only its database; `PUBLIC` cannot connect to it.
`db.env` records `DB_ENGINE`, and `site db-*`, `backup data` (`pg_dump`),
doctor and the healthcheck follow the engine. Names starting with `pg_` are
reserved by PostgreSQL and are prefixed with `site_` automatically.

## MySQL network exposure

```bash
sudo /root/simai-env/simai-admin.sh db network-plan
sudo /root/simai-env/simai-admin.sh db network-localize --ack-no-external yes            # preview
sudo /root/simai-env/simai-admin.sh db network-localize --ack-no-external yes --confirm yes
```

`network-plan` is read-only: it shows the effective bind addresses, listeners,
remote connections and the restriction/rollback plan. `network-localize` binds
the classic and X protocol listeners to `127.0.0.1`. It refuses when a site
`db.env` points at a non-local database host, backs up the configuration,
checks the effective values (`my_print_defaults mysqld`) before restarting,
and restores the backup if MySQL does not come back. Confirm with the owners
that no external client (BI, replication, remote admin) needs MySQL before
running it. Procedure: `docs/operations/env-safety-rollout.md`.
