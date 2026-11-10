# WordPress Commands

WordPress operational commands are available under the `wp` section.
In the interactive menu, the daily WordPress actions appear inside `Applications -> WordPress`.

All commands require a site with `wordpress` profile.

## Status

```bash
simai-admin.sh wp status --domain <domain>
```

Shows:
- database state (`missing-db` / `empty` / `schema` / `installed`)
- web state (`placeholder` / `installer` / `installed`)
- install stage
- WP-CLI availability
- core/config marker presence
- readiness for WP-CLI actions
- Home URL (best effort via `wp option get home`)
- `DISABLE_WP_CRON` mode
- cron file/entry state with managed/domain/slug marker checks
- core version (best effort, when WP-CLI + core are available)

`--output json` answers `simai-wp-status/1`, the site's route and step for
a step tracker (the panel's):

| Field | Meaning |
| --- | --- |
| `route` | `new` (installed by `wp install`), `restore` (by `wp restore-ready`, or a restore being uploaded), `installed` (installed some other way), `none` |
| `step` | `prepare` (nothing yet), `upload` (an archive or a dump is missing), `install` (ready for `wp install` / `wp restore-ready`), `finalize` (profile rules still fail), `done` |
| `next` | the command for the step: `wp:install`, `file:upload`, `wp:restore-ready`, `wp:finalize`, or null |
| `url` | admin URL once installed; installer URL when core files wait for the web installer |
| `pending` | profile rules `wp finalize` will fix |
| `files`, `dumps` | site archives (`.tar.gz`, `.tgz`, `.tar`, core packages excluded) and dumps (`.sql`, `.sql.gz`) found at the top of the site directory or the web root, relative to the site directory |
| `db_state`, `web_state`, `core`, `config`, `wp_cli` | the probes above |

## Install

```bash
simai-admin.sh wp install --domain <domain> --title "<title>" --admin-user <login> --admin-email <email> [--locale ru_RU] [--confirm yes]
```

Installs WordPress end to end on a `wordpress` site with an empty MySQL
database. Without `--confirm yes` it prints the plan and changes nothing.

1. WP-CLI: the official phar, checked against the SHA-512 published next to
   it, installed root-owned as `/usr/local/lib/simai-env/wp-cli.phar`
   (`/usr/local/bin/wp` points to it). It always runs as the site user.
2. Core: the newest official package for the locale (version-check API of
   wordpress.org; `en_US` falls back to `latest.tar.gz`), checked against
   its published SHA-1. Core files already in the docroot are kept.
3. `wp-config.php` from `db.env` with fresh salts from `/dev/urandom`,
   `DISABLE_WP_CRON` true and `WP_DEBUG` false, mode `0640`.
4. `wp core install` as the site user with a generated 24-character admin
   password (passed on stdin, never on a command line); `WPLANG` for a
   non-English locale.
5. `wp finalize`.

The admin password is shown **once**, only in the result: the human output,
`data.admin_password` of `--output json` (schema `simai-wp-install/1`, with
`login_url`, `login_status`, `finalize`), or, in a panel job, the job result
(see docs/architecture/panel-gate.md). It is not written to
`/var/log/simai-admin.log`, the audit log, a job log or any file kept on
disk; WP-CLI output is logged with the password masked. A lost password is
reset with `wp user update <login> --user_pass=...` as the site user, or the
"Lost your password?" link.

Refused when WordPress is already installed, the database already has
WordPress tables, the site has no database or uses PostgreSQL.

## Restore Ready

```bash
simai-admin.sh wp restore-ready --domain <domain> --files <archive> --dump <dump> [--overwrite yes] [--confirm yes]
```

Brings a copy of a WordPress site in: `--files` is a `.tar.gz`, `.tgz` or
`.tar` of the site's files (its docroot, or a folder holding it; an archive
with only `wp-content` gets fresh core files), `--dump` a `.sql` or
`.sql.gz` MySQL dump. Both are paths inside the site directory (relative to
it, or absolute below it), regular files, no `.`/`..` parts and no symlink on
the way: upload them with the file manager first. Without `--confirm yes`
the plan.

1. With `--overwrite yes` and a non-empty database or existing WordPress:
   `backup data` (database and files) first, then the database is emptied.
   Without it such a site is refused.
2. The archive is unpacked as the site user into a staging folder of the
   site directory and copied into the docroot.
3. `wp-config.php`: the copy's own file keeps its salts and settings; its
   `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST` come from `db.env`. A
   copy without one gets a new file. The table prefix follows the dump.
4. The dump is imported as the site user with the site's own credentials (a
   defaults file readable only by that user, removed afterwards): no
   password on a command line, and client commands in a dump never run as
   root.
5. When `home` differs from the site URL: `wp search-replace` of the old
   URL (and `//old-host`) in every table of the prefix, `guid` excluded;
   without WP-CLI only `home` and `siteurl` change.
6. `wp finalize`: an archive or dump left in the web root moves to
   `<site>/restore-archive`.

The copy keeps its own users and passwords; nothing is generated.

## Installer Ready

```bash
simai-admin.sh wp installer-ready --domain <domain> [--overwrite yes] [--archive yes|no] [--archive-overwrite yes|no] [--unpack yes|no] [--config-overwrite yes|no] [--cli-install yes|no]
```

Prepares a real WordPress install flow by:
- provisioning `wp-cli` (best effort)
- downloading the official WordPress archive
- unpacking core files into docroot
- generating `wp-config.php` from `db.env`

This command does not complete the WordPress web installer; it prepares the site so `/wp-admin/install.php` can run cleanly.

## Finalize

```bash
simai-admin.sh wp finalize --domain <domain> --confirm yes [--ssl yes --email <email>] [--redirect yes|no] [--hsts yes|no] [--staging yes|no] [--mode standard|woocommerce-safe]
```

Completes the post-install baseline for a WordPress site that has already finished the web installer:
- ensures `wp-cli` is available (best effort)
- applies WordPress optimization baseline
- rewrites the managed scheduler file
- enforces `DISABLE_WP_CRON=true`
- fixes the WordPress profile rules that fail (`wordpress.leftovers`,
  `wordpress.config-perms`, `wordpress.debug-off`, `wordpress.cron`; see
  docs/commands/site-doctor.md), the same fixes as `site check-fix`; a rule
  that cannot be fixed makes the command fail
- optionally issues Let's Encrypt

If the web installer is not finished yet, the command stops and points back to `/wp-admin/install.php`.

## Cron Status

```bash
simai-admin.sh wp cron-status --domain <domain>
```

Read-only cron diagnostics for WordPress (`/etc/cron.d/<slug>` + `wp-cron.php` entry),
including simai-managed/domain/slug marker checks.

## Cron Sync

```bash
simai-admin.sh wp cron-sync --domain <domain>
```

Rewrites the managed WordPress cron file according to profile defaults.

## Cache Clear

```bash
simai-admin.sh wp cache-clear --domain <domain>
```

Runs `wp cache flush` via `wp-cli` as project user.

Notes:
- Requires `wp` binary in PATH.
- Requires WordPress core/config to be present in docroot.
- Returns non-zero on missing prerequisites.

## Perf Status

```bash
simai-admin.sh wp perf-status --domain <domain>
```

Shows:
- lifecycle state (database/web/install stage)
- managed site performance mode (`site perf-tune` state)
- cron wiring and `DISABLE_WP_CRON`
- permalink structure
- object-cache drop-in presence
- Redis plugin / Redis extension / Redis service state
- WooCommerce plugin presence (best effort)

## Perf Apply

```bash
simai-admin.sh wp perf-apply --domain <domain> --mode standard --confirm yes
```

Supported modes:
- `standard`
- `woocommerce-safe`

Behavior:
- Applies a managed site PHP-FPM governance block (`balanced` for `standard`, `aggressive` for `woocommerce-safe`).
- Rewrites the managed WordPress cron file.
- Forces `DISABLE_WP_CRON=true` in `wp-config.php` when the config file exists.

Notes:
- Requires `--confirm yes` outside interactive menu.
- Does not install cache plugins automatically.

## Practical flow

New site, one command:

1. `simai-admin.sh site add --domain <domain> --profile wordpress --php 8.3 --create-db yes --confirm yes`
2. `simai-admin.sh wp install --domain <domain> --title "My site" --admin-user admin --admin-email admin@example.com --confirm yes`
3. `simai-admin.sh ssl letsencrypt --domain <domain> --email <email>`

A copy of a site: upload the files archive and the dump into the site
directory, then
`simai-admin.sh wp restore-ready --domain <domain> --files site.tar.gz --dump public/db.sql.gz --confirm yes`.

By hand, with the web installer:

1. `simai-admin.sh site add --domain <domain> --profile wordpress --php 8.3 --create-db yes --confirm yes`
2. `simai-admin.sh wp installer-ready --domain <domain>` (the core package is checked against its published SHA-1)
3. Open `/wp-admin/install.php` in the browser and finish web install.
4. `simai-admin.sh wp finalize --domain <domain> --confirm yes`
5. `simai-admin.sh ssl letsencrypt --domain <domain> --email <email>` or use `--ssl yes` during finalize.
