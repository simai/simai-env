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
- readiness for WP-CLI actions
- Home URL (best effort via `wp option get home`)
- `DISABLE_WP_CRON` mode
- cron file/entry state with managed/domain/slug marker checks
- core version (best effort, when WP-CLI + core are available)

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
