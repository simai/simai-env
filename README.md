# simai-env

`simai-env.sh` is a lightweight installer for PHP projects (Laravel optional; generic default) on Ubuntu 20.04/22.04/24.04. It provisions the full stack, configures a project, and supports cleanup mode — with no extra dependencies.

## What it installs
- nginx
- PHP-FPM (8.1/8.2/8.3 via `ppa:ondrej/php`) with extensions: mbstring, intl, curl, zip, xml, gd/imagick, pdo_mysql, opcache
- MySQL Server (or Percona Server 8.0 when `--mysql percona` is set)
- redis
- Node.js (NodeSource; version via `--node-version`, default 20)
- composer
- utilities: git, curl, unzip, htop, rsyslog, logrotate, sudo, certbot

## Default layout
- user: `simai`
- home: `/home/simai/`
- projects: `/home/simai/www/<project>/`
- optional: cron for scheduler and a systemd unit for queues

## Usage (run as root)

### Quick install
 - One-liner (default path `/root/simai-env`):
 ```bash
 curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo bash && \
 sudo /root/simai-env/simai-env.sh --domain example.com --project-name myapp --db-pass secret --php 8.2 --run-migrations --optimize
 ```
 - Two-step variant:
 ```bash
 curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo bash
 sudo /root/simai-env/simai-env.sh --domain example.com --project-name myapp --db-pass secret
 ```
 To pin a specific branch or tag, override `VERSION` (branch) or `REF` (tag), or change `INSTALL_DIR`:
 ```bash
 curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | \
   VERSION=main INSTALL_DIR=/opt/simai-env sudo -E bash
 # or pin a tag
 curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | \
   REF=refs/tags/v1.0.0 sudo -E bash
 ```

### Update scripts only
Refresh to the latest main (or set `REF`/`VERSION`):
```bash
curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/update.sh | sudo bash
```

## Admin CLI (maintenance)
`simai-admin.sh` provides a pluggable command framework and a simple menu wrapper.

- Direct commands:
```bash
sudo /root/simai-env/simai-admin.sh site add --domain example.com --project-name myapp --php 8.2
sudo /root/simai-env/simai-admin.sh db create --name simai_app --user simai --pass secret
sudo /root/simai-env/simai-admin.sh ssl issue --domain example.com --email admin@example.com
sudo /root/simai-env/simai-admin.sh php list
```
- Interactive menu:
```bash
sudo /root/simai-env/simai-admin.sh menu
```
- Self-update via admin CLI:
```bash
sudo /root/simai-env/simai-admin.sh self update
```

Implemented:
- `site add` — profiles: `generic` (default placeholder), `laravel` (requires `artisan`), `alias` (points a new domain to an existing site and reuses its PHP-FPM pool).
- `php list` — shows installed PHP versions and FPM status.
- `self version` — shows local/remote versions.
- `site set-php` — switches PHP version for a site (excludes aliases), recreates pool/nginx upstream.
- `ssl letsencrypt/install/renew/remove/status` — manage Let's Encrypt or custom certificates and nginx HTTPS setup.

Other commands remain as scaffolding stubs; extend `admin/commands/*.sh` to implement them. The registry-based design allows adding sections/commands by registering them in new modules.

See more in `docs/admin.md` and `docs/commands/`.

### New project (mode A)
```bash
./simai-env.sh --domain example.com --project-name myapp \
  --db-name simai_app --db-user simai --db-pass secret \
  --php 8.2 --run-migrations --optimize
```
Actions: creates user `simai` if missing, installs the stack, creates `/home/simai/www/myapp`, runs `composer create-project laravel/laravel myapp`, configures `.env` and `APP_KEY`, sets up nginx + PHP-FPM, cron for `schedule:run`, and a systemd unit for `queue:work`.

### Existing project (mode B)
```bash
./simai-env.sh --existing --path /home/simai/www/project \
  --domain project.local --db-name simai_project --php 8.3
```
Actions: validates Laravel structure, runs `composer install`, creates/updates `.env`, configures nginx + PHP-FPM, cron, and queue worker.

### Cleanup mode
```bash
./simai-env.sh clean --project-name myapp --domain example.com \
  --remove-files --drop-db --drop-db-user
```
Removes nginx config and symlink, the php-fpm pool for the project, cron entry, queue systemd unit, database/user (when flags are set), and the project directory (when flagged).

## Key flags
- `--domain` — required for install and clean
- `--project-name` — project identifier used in paths/services
- `--path` + `--existing` — switch to existing-project flow
- `--php` — PHP version (8.1/8.2/8.3)
- `--mysql` — `mysql` (default) or `percona`
- `--node-version` — Node.js version (NodeSource)
- `--run-migrations`, `--optimize` — run `migrate` and `config:cache/route:cache/view:cache`
- `--silent` — minimal console output (logs still written)
- `--log-file` — custom log path (default `/var/log/simai-env.log`)

## Templates
- `templates/nginx-laravel.conf` — nginx vhost template (`{{SERVER_NAME}}`, `{{PROJECT_ROOT}}`, `{{PHP_VERSION}}`, `{{PROJECT_NAME}}`, `{{PHP_SOCKET_PROJECT}}`)
- `systemd/laravel-queue.service` — queue worker unit (`{{PROJECT_NAME}}`, `{{PROJECT_ROOT}}`, `{{PHP_BIN}}`, `{{USER}}`)

## Logging and cron
- Logs: `/var/log/simai-env.log` (override via `--log-file`)
- Cron: `* * * * * php /home/simai/www/<project>/artisan schedule:run >> /dev/null 2>&1`

## Notes
- No yum/dnf/rpm, no ansible, no Apache.
- Internet access is required for apt, the PPA, NodeSource, and composer.

## License
MIT License — see `LICENSE` for details. Contributions are welcome (see `CONTRIBUTING.md`).
