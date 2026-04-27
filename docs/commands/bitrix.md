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
- nginx SEF fallback state for Bitrix URLs (`/bitrix/urlrewrite.php`)
- nginx static asset compression/cache hints for first page load performance

## Cron Status

```bash
simai-admin.sh bitrix cron-status --domain <domain>
```

Read-only cron diagnostics for Bitrix (`/etc/cron.d/<slug>` + `cron_events.php` entry),
including simai-managed/domain/slug marker checks.

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
- combined readiness flag (`Agents via cron ready`)

## Agents Sync

```bash
simai-admin.sh bitrix agents-sync --domain <domain> [--apply yes] [--confirm yes]
```

- Default is plan-only (`--apply no`).
- Apply mode rewrites managed cron entry and normalizes `dbconn.php` constants for web-safe cron mode (`BX_CRONTAB` removed, `BX_CRONTAB_SUPPORT=true`).
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
simai-admin.sh bitrix restore-ready --domain <domain> [--overwrite yes] [--preseed auto|yes|no] [--short-install yes|no]
```

Prepares a Bitrix site for restore from an existing backup archive:
- downloads `public/restore.php` from the official Bitrix script URL
- normalizes ownership and write permissions for restore-sensitive directories
- optionally writes DB preseed files from site `db.env`
- prints the browser restore URL and the post-restore finalize command

Notes:
- This flow is for backup restore/migration. Use `installer-ready` for a fresh Bitrix install.
- `--preseed auto` writes DB files only when site DB credentials are available.
- `--overwrite yes` refreshes an existing `restore.php`.
- After the browser restore wizard finishes, run `bitrix finalize --domain <domain> --confirm yes`.

## Finalize

```bash
simai-admin.sh bitrix finalize --domain <domain> --confirm yes [--ssl yes --email <email>] [--redirect yes|no] [--hsts yes|no] [--staging yes|no]
```

Safe post-install orchestration for Bitrix sites after the web installer has finished:
- verifies that Bitrix web installation is already complete (`web state = installed`)
- runs `bitrix php-baseline-sync`
- applies `bitrix agents-sync --apply yes`
- optionally issues Let's Encrypt if `--ssl yes --email <email>` is provided

Notes:
- In CLI mode `--confirm yes` is required.
- If the site is still in installer mode, the command stops with a clear error and prints the correct installer URL.
- This is the recommended single step after finishing the Bitrix web installer.

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

Notes:
- Single-domain mode works with `--domain`.
- Bulk mode (`--all yes`) requires `--confirm yes` in CLI mode.
- Read-only checks are not changed; only PHP pool INI overrides are updated.
- run this after Bitrix web installation, before final `site_checker` / `perfmon` acceptance checks.

## Perf Status

```bash
simai-admin.sh bitrix perf-status --domain <domain>
```

Shows:
- managed site performance mode (`site perf-tune` state)
- install stage (`installer` vs `post-install`)
- Bitrix DB/runtime compatibility markers:
  - `.settings.php` init commands
  - `after_connect_d7.php`
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
