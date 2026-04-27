# Admin CLI Overview

`simai-admin.sh` provides maintenance commands with two modes:
- Direct CLI: `sudo /root/simai-env/simai-admin.sh <section> <command> [options]`
- Interactive menu: `sudo /root/simai-env/simai-admin.sh menu` (numeric choices, stays in section; self-update reloads menu)
  - Text backend is the default for stable console UX.
  - After each command, menu shows status/output and waits for Enter before returning.
- Managed file access now lives under `Access`; this batch covers global access to all projects under `WWW_ROOT` and project-scoped access with chroot isolation.

Supported OS: Ubuntu 22.04/24.04. Run as root.

## Profiles
- Registry-driven: defined in `profiles/*.profile.sh` (declarative `PROFILE_` variables only).
- Current profiles:
- `generic` (default): nginx root `<project-root>/public`, creates placeholder page and php-mode healthcheck; optional DB; PHP required.
- `laravel`: nginx root `<project-root>/public`, requires `artisan`/`bootstrap/app.php`; DB required; cron/queue supported.
- `static`: serves `<project-root>/public/index.html`; no PHP/DB; no cron/queue; nginx-mode healthcheck at `/healthcheck` (local-only).
- `alias`: points a new domain to an existing site (reuses target PHP-FPM pool and root); no DB/pool creation.
- `wordpress`: nginx root `<project-root>/public`, requires DB, enables WordPress-oriented nginx routing and recommended cron.
- `bitrix`: nginx root `<project-root>/public`, requires DB, enables Bitrix-oriented routing with basic hardening and recommended cron.
- Public web root is always `<project-root>/public`; default filesystem path is `/home/simai/www/<domain>`, while slug is used for IDs (pool/cron/socket/logs).
See `docs/architecture/profiles.md`.

## Common behaviors
- Domain -> project slug auto-derived if not provided.
- PHP version selection from installed `/etc/php/*` when not passed.
- Healthcheck copied to `public/healthcheck.php` for php-mode profiles; static uses nginx-served `/healthcheck` (local-only); alias inherits target.
- Site removal cleans nginx and PHP-FPM pools; optional files/DB/user removal via prompts (alias removal only drops nginx).
- Site doctor: read-only diagnostics against profile (filesystem, nginx, PHP, cron, SSL, DB) with PASS/WARN/FAIL summary; for Bitrix it also warns about root-owned docroot files that can break module uninstall/update. It does not apply changes.
- Laravel daily ops (`laravel status`, `laravel app-ready`, `laravel finalize`, `laravel perf-status`, `laravel perf-apply`) provide low-risk application bootstrap, post-bootstrap baseline, and optimization checks for laravel profile sites.
- WordPress daily ops (`wp status`, `wp installer-ready`, `wp finalize`, `wp cron-status`, `wp cron-sync`, `wp cache-clear`) provide low-risk operational checks and install/scheduler/cache maintenance for wordpress profile sites.
- Bitrix daily ops (`bitrix status`, `bitrix finalize`, `bitrix ownership`, `bitrix cron-status`, `bitrix cron-sync`, `bitrix agents-status`, `bitrix agents-sync`, `bitrix cache-clear`) provide low-risk operational checks and post-install/scheduler/cache/ownership maintenance for bitrix profile sites.
- In the interactive menu, these daily application/CMS actions live under `Applications`, which opens separate submenus for Laravel, WordPress, and Bitrix.
- PHP commands: list/reload installed versions, and `php install` to add a new PHP version (uses ondrej/php, installs FPM/CLI/common extensions, with post-install tests).
- Site list shows domain, profile, PHP version, root/alias target, and brief SSL status.
- Logging:
  - Platform log: `/var/log/simai-admin.log`.
  - Command audit log: `/var/log/simai-audit.log` records command start/finish with user, section/command, redacted args, exit code, and correlation ID.
  - Setup log: `/var/log/simai-env.log`.

## System and automation
- User guide for menu-driven work: `docs/guide/menu-user-guide.md`.
- Command reference for this section: `docs/commands/self.md`.
- Production rollout gate: `docs/operations/production-readiness.md`.

## Self commands
- `self update`: update scripts in place (reloads menu when invoked from menu).
  - Honors update source from `/etc/simai-env.conf`: `SIMAI_UPDATE_REF` (`refs/heads/...` or `refs/tags/...`) or `SIMAI_UPDATE_BRANCH`.
  - Creates best-effort pre-update backup at `/root/simai-backups/simai-env-preupdate-<timestamp>.tar.gz` for manual rollback.
  - Runs a fast post-update smoke check (`bash -n` + executable presence). Set `SIMAI_UPDATE_SMOKE_STRICT=yes` to fail update on smoke errors.
- `self version`: show local/remote versions to know if an update is available (including configured update ref).
- `self auto-update-status`: show cached automatic update state (`off|check|apply-safe`), last check time, and cached local/remote versions.
- `self auto-update-enable-check` / `self auto-update-enable-apply` / `self auto-update-disable`: control automatic update checks in `/etc/simai-env.conf`.
- `self auto-update-run-check`: refresh update availability now without applying the update.
- In `apply-safe` mode, the interactive menu applies updates only at safe points (section boundaries / post-command return) and restores the same menu section after restart.
- `self scheduler`: run one internal scheduler tick (the command used by the managed system cron entry).
- `self scheduler-status`: show whether the shared scheduler cron is installed, plus job state/last run/next due.
- `self scheduler-enable --job all|auto-optimize|health-review|site-review` / `self scheduler-disable --job all|auto-optimize|health-review|site-review`: enable or disable the shared scheduler globally or per job without touching the cron entry itself.
- `self scheduler-run --job auto-optimize|health-review|site-review`: run one scheduler job immediately for testing/debugging.
- `self auto-optimize-status`: show the simple user-facing automatic optimization state without exposing low-level scheduler details.
- `self auto-optimize-enable` / `self auto-optimize-disable`: turn automatic optimization on or off globally while leaving the shared scheduler infrastructure in place.
- `self health-review-status`: show the latest read-only platform review produced by the shared scheduler.
- `self site-review-status`: show the latest read-only review of unfinished sites, stale setup candidates, and sites that are good pause candidates.
- `self perf-status`: show current server optimization status, detected server size, recommended preset, live nginx/mysql/redis/FPM pressure signals, and estimated FPM oversubscription.
- `self perf-plan --limit <n>`: show the heaviest PHP-FPM pools on the server, plus usage-aware suggested target modes (`safe`, `balanced`, `parked`) for the full server footprint.
- `self perf-rebalance --limit <n> --mode auto|safe|parked --confirm yes`: apply `site perf-tune` to the heaviest eligible pools, reducing global FPM oversubscription in controlled batches. `auto` respects the site usage class.
- `self perf-apply --preset small|medium|large --confirm yes`: apply a managed server baseline for future PHP-FPM pools, PHP OPcache, nginx, MySQL, and Redis (when installed).
- The regular System menu uses user-facing labels such as `Platform status`, `Optimization status`, `Automatic updates`, and `Check for updates now`; scheduler internals, `Health review`, and `Site review` remain in Advanced mode.
- `site perf-status --domain <domain>`: inspect current per-site PHP-FPM governance, socket/service state, pool share, estimated global FPM oversubscription, memory risk, and cron/queue footprint.
- `site info`, `site usage-status`, and `site perf-status` now include a simple optimization posture plus a plain-language recommendation so ordinary users can understand the current state without reading raw FPM values first.
- `site perf-tune --domain <domain> --mode parked|safe|balanced|aggressive --confirm yes`: apply site-level FPM governance without touching nginx/MySQL/Redis.
- `site usage-status --domain <domain>` / `site usage-set --domain <domain> --class standard|high-traffic|rarely-used --confirm yes`: simple user-facing site activity class mapped to the internal performance engine.
- `site auto-optimize-status --domain <domain>` / `site auto-optimize-enable|disable|reset --domain <domain> --confirm yes`: per-site override for automatic optimization; useful when one site should be excluded from scheduler-driven automatic changes.
- `site runtime-status --domain <domain>`: show whether the site runtime is active or suspended and whether its pool/cron/queue are currently enabled.
- `site add --domain <domain> --host-mode wildcard`: create one site that serves both the main domain and all first-level subdomains (`*.domain`) on the same nginx vhost.
- `ssl letsencrypt --domain <domain> --wildcard yes --dns-provider cloudflare --dns-credentials <file>`: request one Let's Encrypt cert for both the main domain and all first-level subdomains of a wildcard-host site.
- In the menu, these are intentionally phrased in simpler language such as `Activity & optimization`, `Automatic optimization for this site`, `Site availability`, `Pause site`, `Resume site`, `Optimization plan`, `Database server status`, and `Configuration check`.
- `site runtime-suspend --domain <domain> --confirm yes`: suspend a site runtime by disabling its PHP-FPM pool, parking nginx behind a managed `503`, and disabling cron/queue where applicable.
- `site runtime-resume --domain <domain> --confirm yes`: restore a previously suspended site runtime.
- `laravel status --domain <domain>`: show Laravel lifecycle state (`placeholder`, `app-ready`, `post-install`) and the next practical action.
- `laravel app-ready --domain <domain>`: bootstrap a real Laravel application via Composer and prepare `.env` from SIMAI DB credentials.
- `laravel finalize --domain <domain> --confirm yes [--migrate yes] [--ssl yes --email <email>]`: complete Laravel post-bootstrap baseline (APP_KEY, storage link, scheduler, baseline optimization, optional migrations and Let's Encrypt).
- `laravel perf-status --domain <domain>` / `laravel perf-apply --domain <domain> --mode safe|balanced|aggressive --confirm yes`: Laravel optimization status and apply flow.
- `wp perf-status --domain <domain>` / `wp perf-apply --domain <domain> --mode standard|woocommerce-safe --confirm yes`: WordPress optimization status and apply flow.
- `wp installer-ready --domain <domain>`: prepare WordPress core files, generated `wp-config.php`, and `wp-cli` so the browser installer can run cleanly.
- `wp finalize --domain <domain> --confirm yes [--ssl yes --email <email>]`: complete a finished WordPress web install in one step (optimization baseline + scheduler baseline + optional Let's Encrypt).
- `bitrix perf-status --domain <domain>` / `bitrix perf-apply --domain <domain> --mode standard|high-load --confirm yes`: Bitrix optimization status and apply flow (site tune + PHP baseline + installer-aware agents/cache steps).
- `bitrix finalize --domain <domain> --confirm yes [--ssl yes --email <email>]`: finalize a completed Bitrix web install in one step (PHP baseline + agents sync + optional Let's Encrypt).
- `bitrix ownership --domain <domain> [--apply yes --confirm yes]`: detect and repair root-owned Bitrix web files and managed symlinked module checkouts after root-run installs, restores, or deployments.

## Internal scheduler
- Bootstrap now installs one shared cron entry: `/etc/cron.d/simai-scheduler`.
- The cron entry stays stable and always calls `simai-admin.sh self scheduler`.
- Individual background capabilities are enabled/disabled inside simai-env, not by editing cron lines.
- Ordinary users can treat this as one switch via `self auto-optimize-enable` / `self auto-optimize-disable`; Advanced mode still exposes scheduler details and manual job control.
- Current built-in job:
- `auto_optimize`: policy-driven performance maintenance for oversubscribed PHP-FPM servers.
- `health_review`: recurring read-only platform health summary.
- `site_review`: recurring read-only review of unfinished, stale, or pause-candidate sites.
- `auto_optimize` now uses usage-aware targets by default:
  - `standard` -> `safe`
  - `high-traffic` -> `balanced`
  - `rarely-used` -> `parked`
- Managed config keys in `/etc/simai-env.conf`:
  - `SIMAI_SCHEDULER_ENABLED=yes|no`
  - `SIMAI_AUTO_OPTIMIZE_ENABLED=yes|no`
  - `SIMAI_AUTO_OPTIMIZE_MODE=observe|assist|manual`
  - `SIMAI_AUTO_OPTIMIZE_INTERVAL_MINUTES=<n>`
  - `SIMAI_AUTO_OPTIMIZE_COOLDOWN_MINUTES=<n>`
  - `SIMAI_AUTO_OPTIMIZE_LIMIT=<n>`
  - `SIMAI_AUTO_OPTIMIZE_REBALANCE_MODE=auto|safe|parked`

## Non-Interactive Contract
Use this section when running commands from automation (CI, cron, deploy scripts).

- Prefer direct CLI mode (`simai-admin.sh <section> <command> ...`), not `menu`.
- Treat exit code `0` as success and non-zero as failure.
- In menu mode, cancel actions are intentionally non-fatal to the menu session, but they are now reported distinctly as `CANCELLED` instead of `SUCCESS`.

### Output channels
- Command output is primarily printed to stdout.
- Operational logs are also written to `/var/log/simai-admin.log`.
- Audit trail is written to `/var/log/simai-audit.log` with redacted arguments.

### Color control
- Disable ANSI colors in automation with `NO_COLOR=1` or `SIMAI_UI_COLOR=never`.
- Force colors for interactive troubleshooting with `SIMAI_UI_COLOR=always`.

### Recommended automation pattern
```bash
NO_COLOR=1 /root/simai-env/simai-admin.sh self status >/tmp/simai-status.txt
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "simai status failed" >&2
  exit $rc
fi
```

### Menu backend switches
- `SIMAI_MENU_BACKEND=text` forces text menu backend.
- `SIMAI_MENU_BACKEND=whiptail` enables optional `whiptail` backend (falls back safely when unavailable).
- Backend can also be switched during menu session: `System -> Menu backend`.

Commands detail: see `docs/commands/*`.
Daily profile mapping: `docs/operations/profile-ops-matrix.md`.
