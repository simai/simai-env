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

## Cache Clear

```bash
simai-admin.sh bitrix cache-clear --domain <domain>
```

Clears Bitrix cache directories:
- `bitrix/cache`
- `bitrix/managed_cache`
- `bitrix/stack_cache`
