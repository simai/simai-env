# WordPress Commands

WordPress operational commands are available under the `wp` section.
In the interactive menu, the daily WordPress actions currently appear inside the shared `Laravel` section.

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

1. `simai-admin.sh site add --domain <domain> --profile wordpress --php 8.3 --db yes`
2. `simai-admin.sh wp installer-ready --domain <domain>`
3. Open `/wp-admin/install.php` in the browser and finish web install.
4. `simai-admin.sh wp finalize --domain <domain> --confirm yes`
5. `simai-admin.sh ssl letsencrypt --domain <domain> --email <email>` or use `--ssl yes` during finalize.
