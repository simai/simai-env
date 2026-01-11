# Architecture Overview

simai-env is a bash-based installer and admin toolkit for hosting PHP sites on Ubuntu (22.04/24.04).

- Installer (`simai-env.sh`): bootstraps base stack (nginx, PHP-FPM, MySQL/Percona, redis, Node.js, certbot, composer), creates sites, and supports cleanup. No demo sites are created automatically.
- Admin CLI (`simai-admin.sh`): registry-driven commands with an interactive menu and audit logging.
- Profiles: declarative site types defined in `profiles/*.profile.sh`; current profiles: generic, laravel, static, alias. All profiles use `<project-root>/public` as web root; projects live at `/home/simai/www/<domain>` by default and use slug only for IDs (pool/cron/socket/logs).
- Templates: nginx vhosts in `templates/nginx-*.conf`, queue unit in `systemd/laravel-queue.service`, healthcheck in `templates/healthcheck.php`.
- Static profile uses nginx-served `/healthcheck` (local-only); PHP profiles use `public/healthcheck.php` (local-only).
- Metadata: nginx configs embed `# simai-*` headers (domain/profile/project/root/php/target/php-socket-project/ssl) as the single source of truth for site state.
- Paths:
  - Install dir: `/root/simai-env`
- Projects: `/home/simai/www/<domain>/`
  - Nginx: `/etc/nginx/sites-available/<domain>.conf` (+ symlink in `sites-enabled`)
  - SSL: `/etc/letsencrypt/live/<domain>/` and `/etc/nginx/ssl/<domain>/`
  - Logs: `/var/log/simai-env.log`, `/var/log/simai-admin.log`, `/var/log/simai-audit.log`
- Security defaults: dedicated user `simai`, per-site PHP-FPM pools (except static/alias), catch-all default_server returning 444, secrets never logged, public/ is always the web root, idempotent operations.
