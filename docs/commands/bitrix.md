# Bitrix Commands

Bitrix operational commands are available under the `bitrix` section.
In the interactive menu, the daily Bitrix actions appear inside `Applications -> Bitrix`.

All commands require a site with `bitrix` profile.

## Status

```bash
simai-admin.sh bitrix status --domain <domain>
```

Shows:
- core marker presence
- `.settings.php` presence
- `dbconn.php` presence
- `BX_CRONTAB` mode (best effort from `dbconn.php`)
- `BX_CRONTAB_SUPPORT` mode (best effort from `dbconn.php`)
- `cron_events.php` entrypoint presence
- cron file/entry state with managed/domain/slug marker checks
- nginx upload body limit for Bitrix FileInput uploads (`client_max_body_size 64m`)
- nginx SEF fallback state for Bitrix URLs (`/bitrix/urlrewrite.php`)
- nginx static asset compression/cache hints for first page load performance

With `--output json` (`simai-bitrix-status/1`, also `bitrix:status` in the
panel gateway) it answers where the site is on its way:
- `route`: `restore` (restore.php in the web root, or a site restored
  earlier), `setup` (bitrixsetup.php), `installed`, `none`;
- `step`: `prepare` (no wizard yet: `bitrix restore-ready` or
  `installer-ready`), `upload` (restore.php, no archive), `validate`
  (archive uploaded, not checked by `restore-ready` yet, or changed since),
  `run_restore` (open `restore_url`), `run_setup` (open `installer_url`),
  `finalize` (installed; `pending` lists the profile rules `bitrix finalize`
  fixes), `done`;
- `next`: the command for the step, or `open_url`.
`restore-ready` remembers the archive it validated (name and size) in
`/etc/simai-env/sites/<domain>/bitrix-restore.env`.

## Cron Status

```bash
simai-admin.sh bitrix cron-status --domain <domain>
```

Read-only cron diagnostics for Bitrix (`/etc/cron.d/<slug>` + `cron_events.php` entry),
including simai-managed/domain/slug marker checks and the CLI `short_open_tag=1`
flag required by legacy Bitrix core files that still contain short PHP tags.

## Cron Sync

```bash
simai-admin.sh bitrix cron-sync --domain <domain>
```

Rewrites the managed Bitrix cron file according to profile defaults.

## Agents Status

```bash
simai-admin.sh bitrix agents-status --domain <domain>
```

Read-only status for "agents via cron" baseline:
- `BX_CRONTAB`
- `BX_CRONTAB_SUPPORT`
- cron marker consistency for `/etc/cron.d/<slug>`
- CLI `short_open_tag=1` marker in the cron command
- combined readiness flag (`Agents via cron ready`)

## Agents Sync

```bash
simai-admin.sh bitrix agents-sync --domain <domain> [--apply yes] [--confirm yes]
```

- Default is plan-only (`--apply no`).
- Apply mode rewrites managed cron entry with `php -d short_open_tag=1 ... cron_events.php` and normalizes `dbconn.php` constants for web-safe cron mode (`BX_CRONTAB` removed, `BX_CRONTAB_SUPPORT=true`).
- In CLI mode use `--confirm yes` with `--apply yes`.
- Creates `dbconn.php.bak.<timestamp>` before modification.

## Cache Clear

```bash
simai-admin.sh bitrix cache-clear --domain <domain>
```

Clears Bitrix cache directories:
- `bitrix/cache`
- `bitrix/managed_cache`
- `bitrix/stack_cache`

## Ownership

```bash
simai-admin.sh bitrix ownership --domain <domain>
simai-admin.sh bitrix ownership --domain <domain> --apply yes --confirm yes
```

Checks and repairs root-owned files that can block Bitrix module install,
uninstall, cache cleanup, and web-based file operations.

The command scans:
- the Bitrix docroot
- symlinked module targets under the managed SIMAI web/git paths

Repair mode changes web files to `simai:www-data` and git checkout targets to
`simai:simai`. Use this after restoring archives, running module installers
from a root shell, or repairing a deployment that left module files owned by
`root`.

## DB Preseed

```bash
simai-admin.sh bitrix db-preseed --domain <domain> [--overwrite yes] [--short-install yes|no]
```

Generates Bitrix DB configuration files from site `db.env`:
- `public/bitrix/.settings.php`
- `public/bitrix/php_interface/dbconn.php`

Notes:
- Safe for installer flow; no secrets are printed to console.
- By default it does not overwrite existing non-empty files.
- Use `--overwrite yes` to force regeneration.
- By default preseed writes `SHORT_INSTALL=true` into `dbconn.php` to simplify Bitrix install flow.
- Before SSL is enabled, open installer/status URLs over `http://`, not `https://`.
- `bitrixsetup.php` is downloaded best effort from the official Bitrix URL, but its current upstream behavior should be verified: if status reports `Setup kind = bitrix24-loader`, do not treat it as a confirmed Site Management installer.
- Preseed does not enable agents-via-cron by itself; `BX_CRONTAB_SUPPORT` is added only by explicit `bitrix agents-sync --apply yes`.
- Use `--short-install no` if full/manual installer flow is required.

## Installer Ready

```bash
simai-admin.sh bitrix installer-ready --domain <domain> [--overwrite yes] [--short-install yes|no] [--setup-overwrite yes|no] [--archive yes|no] [--edition start|standard|small-business|business] [--archive-overwrite yes|no] [--unpack yes|no]
```

Prepares Bitrix installer flow in one step:
- generates/updates DB preseed files from `db.env`
- downloads `public/bitrixsetup.php` from official Bitrix URL (best effort)
- downloads a local Site Management distro archive (`.tar.gz`) for the selected edition by default
- unpacks the archive into docroot by default to expose the regular Site Management web installer at `/`

Notes:
- default mode keeps existing files (`--overwrite no`, `--setup-overwrite no`, `--archive-overwrite no`).
- command is safe for repeat runs (idempotent).
- if network is unavailable, setup script step can fail while DB preseed still stays valid.
- default `--edition standard` is used for a predictable fresh trial flow.
- default `--unpack yes` is recommended because current upstream `bitrixsetup.php` may behave as a generic Bitrix24 loader instead of a direct Site Management installer.
- if `--unpack no` is used, open `bitrixsetup.php?test=1` so BitrixSetup can work with the local distro archive.
- recommended usage order for fresh sites:
  1. `site add --profile bitrix --db yes`
  2. `bitrix installer-ready --domain <domain>`
  3. complete web installer
  4. `bitrix finalize --domain <domain> --confirm yes`
  5. `ssl letsencrypt --domain <domain> --email <email>` (or use `bitrix finalize --ssl yes --email <email>`)

Notes:
- `bitrix status` now probes the real web state and distinguishes `installer`, `installed`, `placeholder`, and `unknown`.
- When unpacked distro files are present, the recommended installer URL is the site root `/`, not `bitrixsetup.php`.

## Restore Ready

```bash
simai-admin.sh bitrix restore-ready --domain <domain> [--overwrite yes] [--preseed auto|yes|no] [--short-install yes|no] [--archive auto|none|<filename>]
```

Prepares a Bitrix site for restore from an existing backup archive:
- downloads `public/restore.php` from the official Bitrix script URL
- normalizes ownership and write permissions for restore-sensitive directories
- optionally writes `.settings.php` and connection initialization from site `db.env`; restore mode deliberately leaves `dbconn.php` to the archive
- validates every volume of an uploaded Bitrix `tar.gz` backup before printing the browser restore URL
- prints the browser restore URL and the post-restore finalize command

Notes:
- This flow is for backup restore/migration. Use `installer-ready` for a fresh Bitrix install.
- `--preseed auto` writes restore-safe DB connection files only when site DB credentials are available. It does not create or overwrite `dbconn.php`, because a premature UTF-8 marker can trigger obsolete `mbstring.func_overload` validation before a PHP 8-compatible archive is unpacked.
- `--overwrite yes` refreshes an existing `restore.php`.
- With the default `--archive auto`, run the command again after uploading all archive volumes. If no archive is present, it prints upload and validation steps instead of inviting the operator to open the wizard.
- A missing or corrupt volume fails closed and names the first bad file. `--archive <filename>` selects one base archive when several are present. `--archive none` is an explicit advanced bypass.
- After the browser restore wizard finishes, run `bitrix finalize --domain <domain> --confirm yes`.

## Finalize

```bash
simai-admin.sh bitrix finalize --domain <domain> --confirm yes [--ssl yes --email <email>] [--redirect yes|no] [--hsts yes|no] [--staging yes|no]
```

Safe post-install and post-restore orchestration for Bitrix sites after the web installer or the `restore.php` wizard has finished:
- verifies that Bitrix web installation is already complete (`web state = installed`)
- moves restore leftovers out of the docroot (see below)
- makes `bitrix/php_interface/after_connect_d7.php` set `SET SESSION sql_mode=''` and `SET SESSION innodb_strict_mode=0`
- sets the site database default charset/collation to the profile values (`utf8mb4` / `utf8mb4_unicode_ci`)
- runs `bitrix php-baseline-sync` (including PHP `date.timezone`)
- applies `bitrix agents-sync --apply yes`
- optionally issues Let's Encrypt if `--ssl yes --email <email>` is provided

Each step is shown in the result table. The command is idempotent: a second run
reports every step as unchanged. It is also safe on a fresh install.

Restore leftovers:
- A restore leaves the archive volumes, `restore.php` and the database dump in the public docroot, where they can be downloaded.
- Finalize moves (never deletes) them into `<site root>/restore-archive/` (mode `0700`, site user), next to but outside the docroot, and prints the destination.
- Only these files are moved: top-level backup volumes named like Bitrix backups (`<name>_<type>_<id>.tar.gz`, `.tar.gz.N`, `.enc.gz`, `.enc.gz.N`), top-level `restore.php`, and `bitrix/backup/*.sql`. Distribution archives (`*_encode.tar.gz`), other files and symlinks stay.
- A file whose name already exists in `restore-archive/` gets a timestamp prefix.
- When the docroot is the site root itself, nothing is moved and the step fails with a message.

MySQL session modes:
- The archive replaces `.settings.php` (a connection without the toolkit's `init_commands`) and `after_connect_d7.php` (often only `SET NAMES`). Bitrix then runs under the server's strict `sql_mode` and `innodb_strict_mode=ON`.
- Finalize appends only the missing statements to `after_connect_d7.php`, in the style the file uses (`$this->queryExecute(...)` or `$connection->queryExecute(...)`), keeps the existing lines (charset and collation are not rewritten), removes a trailing `?>`, checks the result with `php -l`, keeps owner and mode, and replaces the file atomically. A missing file is created from the toolkit template.
- `.settings.php` and its credentials are never changed or printed.

Database charset:
- The archive's `*_after_connect.sql` can run `ALTER DATABASE ... COLLATE utf8mb3_general_ci`, so the database default differs from the `utf8mb4` connection (site checker warning).
- Finalize changes only the database default with `ALTER DATABASE`; tables are never converted. The number of tables that still use `utf8mb3` is reported for information.

Notes:
- In CLI mode `--confirm yes` is required.
- If the site is still in installer mode, the command stops with a clear error and prints the correct installer URL.
- This is the recommended single step after finishing the Bitrix web installer or the restore wizard.
- If a step fails, the remaining steps still run, the table names the failure and the command exits non-zero.

## PHP Baseline Sync

```bash
simai-admin.sh bitrix php-baseline-sync --domain <domain>
simai-admin.sh bitrix php-baseline-sync --all yes --confirm yes
```

Applies Bitrix PHP INI baseline via `site fix` (`--apply php-ini`), with
`--include-recommended yes` by default.
Then enforces critical FPM keys per site:
- `memory_limit=512M`
- `opcache.validate_timestamps=1`
- `opcache.revalidate_freq=0`
- `date.timezone` set to the host time zone (`timedatectl`, then `/etc/timezone`, then `/etc/localtime`; `UTC` when none is valid), so PHP and MySQL agree on the time. Only added when the site has no `date.timezone` override yet; `site php-ini-set --name date.timezone` keeps the operator's value.

Other per-site overrides set with `site php-ini-set` are kept; the baseline keys win.

Host baseline: OPcache memory cannot be set per pool (one shared memory per
PHP version), so before the pool step the command writes
`/etc/php/<version>/fpm/conf.d/99-zz-simai-opcache.ini` for the PHP version of
each target site:
- `opcache.memory_consumption=256`
- `opcache.interned_strings_buffer=16`
- `opcache.max_accelerated_files=20000`
- `realpath_cache_ttl=600`

Each value is the larger of the baseline and what the other ini files of that
version set, so a higher value chosen by an administrator (in their own
`conf.d` file) stays; the file loads last, so the `self perf-apply` preset
cannot lower it. It is validated with `php-fpm<version> -t` (restored on
failure) and PHP-FPM reloads only when it changed. `site add` / `site set-php`
of a Bitrix site and `self migrate` (for every version that serves a Bitrix
site) write the same file; `site doctor` then reports these four checks as
`PASS`.

Notes:
- Single-domain mode works with `--domain`.
- Bulk mode (`--all yes`) requires `--confirm yes` in CLI mode.
- Read-only checks are not changed; only PHP pool INI overrides and the host
  baseline file above are updated.
- run this after Bitrix web installation, before final `site_checker` / `perfmon` acceptance checks.

## Perf Status

```bash
simai-admin.sh bitrix perf-status --domain <domain>
```

Shows:
- managed site performance mode (`site perf-tune` state)
- install stage (`installer` vs `post-install`)
- Bitrix DB/runtime compatibility markers:
  - `.settings.php` init commands (`ready (via after_connect_d7.php)` when a restored `.settings.php` has none but `after_connect_d7.php` sets the session modes)
  - `after_connect_d7.php` (`ready` when it sets an empty `sql_mode` and `innodb_strict_mode=0`)
  - agents-via-cron readiness
- effective PHP-FPM runtime values used by Bitrix checker-sensitive paths
- cache directory presence
- Redis extension/service availability

## Perf Apply

```bash
simai-admin.sh bitrix perf-apply --domain <domain> --mode standard --confirm yes
```

Supported modes:
- `standard`
- `high-load`

Behavior:
- Applies a managed site PHP-FPM governance block (`balanced` for `standard`, `aggressive` for `high-load`).
- Runs `bitrix php-baseline-sync` for PHP/FPM runtime enforcement.
- Applies `bitrix agents-sync` automatically only after installer stage is over (`SHORT_INSTALL != true`).
- Clears Bitrix caches automatically only after installer stage is over.

Notes:
- Requires `--confirm yes` outside interactive menu.
- Installer-stage Bitrix sites keep agents/cache steps in `skipped (installer)` state by design.
