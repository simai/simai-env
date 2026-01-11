# php commands

Run with `sudo /root/simai-env/simai-admin.sh php <command> [options]` or via menu.

## list
List installed PHP versions with FPM status and pool counts.

## reload
Reload or restart a PHP-FPM service.

Options:
- `--php` (required outside menu) – version, e.g. `8.2`

Behavior:
- Runs `systemctl reload php<ver>-fpm` (fallback restart).

## install
Install a PHP version (FPM/CLI + base extensions) using the ondrej/php repository.

Options:
- `--php` (required outside menu; menu offers 8.1/8.2/8.3/8.4)
- `--include-common` (`yes|no`, default `yes`) – install common extensions (curl/mbstring/xml/zip/gd/intl/mysql/bcmath/opcache)
- `--confirm` (`yes|no`, default `no`; required in CLI when installation is needed)

Behavior:
- Validates version and ensures the ondrej/php PPA is present (adds it if missing).
- Detects missing packages; if none, exits with PASS.
- CLI requires `--confirm yes` when packages must be installed; menu prompts to proceed.
- Runs `apt-get update` and installs missing packages via `run_long`; then `php-fpm<ver> -t` and enables/starts `php<ver>-fpm`.
- Prints a summary with binaries/service status and next steps for switching a site.
- In menu flows, `site add` / `site set-php` can offer to install a selected supported version if it is missing.

Examples:
- Plan/skip if already installed: `simai-admin.sh php install --php 8.3`
- Install with common extensions: `simai-admin.sh php install --php 8.3 --confirm yes`
- Install without common extensions: `simai-admin.sh php install --php 8.3 --include-common no --confirm yes`
