# WordPress Commands

WordPress operational commands are available under the `wp` section.

All commands require a site with `wordpress` profile.

## Status

```bash
simai-admin.sh wp status --domain <domain>
```

Shows:
- WP-CLI availability
- core/config marker presence
- `DISABLE_WP_CRON` mode
- cron file/entry state
- core version (best effort, when WP-CLI + core are available)

## Cron Status

```bash
simai-admin.sh wp cron-status --domain <domain>
```

Read-only cron diagnostics for WordPress (`/etc/cron.d/<slug>` + `wp-cron.php` entry).

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
