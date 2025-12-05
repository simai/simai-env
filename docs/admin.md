# Admin CLI Overview

`simai-admin.sh` provides maintenance commands with two modes:
- Direct CLI: `sudo /root/simai-env/simai-admin.sh <section> <command> [options]`
- Interactive menu: `sudo /root/simai-env/simai-admin.sh menu` (numeric choices, stays in section; self-update reloads menu)

Supported OS: Ubuntu 20.04/22.04/24.04. Run as root.

## Profiles
- `generic` (default): nginx root `<project>/public`, creates placeholder page and healthcheck; can create `.env` for DB.
- `laravel`: nginx root `<project>/public`, requires `artisan`.
- `alias`: points a new domain to an existing site (reuses target PHP-FPM pool and root); no DB/pool creation.

## Common behaviors
- Domain -> project slug auto-derived if not provided.
- PHP version selection from installed `/etc/php/*` when not passed.
- Healthcheck copied to `public/healthcheck.php` (non-alias profiles).
- Site removal cleans nginx and PHP-FPM pools; optional files/DB/user removal via prompts (alias removal only drops nginx).
- Site list shows domain, profile, PHP version, root/alias target, and brief SSL status.
- Logging:
  - Admin log: `/var/log/simai-admin.log`.
  - Audit log: `/var/log/simai-audit.log` records command start/finish with user, section/command, redacted args, exit code, and correlation ID.
  - Installer log: `/var/log/simai-env.log`.

## Self commands
- `self update`: update scripts in place (reloads menu when invoked from menu).
- `self version`: show local/remote versions to know if an update is available.

Commands detail: see `docs/commands/*`.
