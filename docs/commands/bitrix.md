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
