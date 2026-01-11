# Admin CLI Overview

`simai-admin.sh` provides maintenance commands with two modes:
- Direct CLI: `sudo /root/simai-env/simai-admin.sh <section> <command> [options]`
- Interactive menu: `sudo /root/simai-env/simai-admin.sh menu` (numeric choices, stays in section; self-update reloads menu)

Supported OS: Ubuntu 22.04/24.04. Run as root.

## Profiles
- Registry-driven: defined in `profiles/*.profile.sh` (declarative `PROFILE_` variables only).
- Current profiles:
- `generic` (default): nginx root `<project-root>/public`, creates placeholder page and php-mode healthcheck; optional DB; PHP required.
- `laravel`: nginx root `<project-root>/public`, requires `artisan`/`bootstrap/app.php`; DB required; cron/queue supported.
- `static`: serves `<project-root>/public/index.html`; no PHP/DB; no cron/queue; nginx-mode healthcheck at `/healthcheck` (local-only).
  - `alias`: points a new domain to an existing site (reuses target PHP-FPM pool and root); no DB/pool creation.
- Public web root is always `<project-root>/public`; default filesystem path is `/home/simai/www/<domain>`, while slug is used for IDs (pool/cron/socket/logs).
See `docs/architecture/profiles.md`.

## Common behaviors
- Domain -> project slug auto-derived if not provided.
- PHP version selection from installed `/etc/php/*` when not passed.
- Healthcheck copied to `public/healthcheck.php` for php-mode profiles; static uses nginx-served `/healthcheck` (local-only); alias inherits target.
- Site removal cleans nginx and PHP-FPM pools; optional files/DB/user removal via prompts (alias removal only drops nginx).
- Site doctor: read-only diagnostics against profile (filesystem, nginx, PHP, cron, SSL, DB) with PASS/WARN/FAIL summary; does not apply changes.
- PHP commands: list/reload installed versions, and `php install` to add a new PHP version (uses ondrej/php, installs FPM/CLI/common extensions, with post-install tests).
- Site list shows domain, profile, PHP version, root/alias target, and brief SSL status.
- Logging:
  - Admin log: `/var/log/simai-admin.log`.
  - Audit log: `/var/log/simai-audit.log` records command start/finish with user, section/command, redacted args, exit code, and correlation ID.
  - Installer log: `/var/log/simai-env.log`.

## Self commands
- `self update`: update scripts in place (reloads menu when invoked from menu).
- `self version`: show local/remote versions to know if an update is available.

Commands detail: see `docs/commands/*`.
