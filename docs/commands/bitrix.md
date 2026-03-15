# Bitrix Commands

Bitrix operational commands are available under the `bitrix` section.

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
- Apply mode updates `dbconn.php` constants (`BX_CRONTAB=true`, `BX_CRONTAB_SUPPORT=true`) and rewrites managed cron entry.
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

## DB Preseed

```bash
simai-admin.sh bitrix db-preseed --domain <domain> [--overwrite yes]
```

Generates Bitrix DB configuration files from site `db.env`:
- `public/bitrix/.settings.php`
- `public/bitrix/php_interface/dbconn.php`

Notes:
- Safe for installer flow; no secrets are printed to console.
- By default it does not overwrite existing non-empty files.
- Use `--overwrite yes` to force regeneration.

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
