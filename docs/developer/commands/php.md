# `php` Commands

Run with `sudo /root/simai-env/simai-admin.sh php <command> [options]` or via menu.

Use this group to inspect installed PHP versions, install a new version, or reload PHP-FPM.

## list
List installed PHP versions with FPM status and pool counts.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh php list
```

This is the command used by `PHP -> List PHP versions`.

## reload
Reload or restart one PHP-FPM service.

Options:
- `--php <version>` (required outside menu), for example `8.3`

Behavior:
- tries `systemctl reload php<version>-fpm`
- falls back to restart when reload is not enough

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh php reload --php 8.3
```

## install
Install a PHP version and the base runtime packages.

Options:
- `--php <version>` (required outside menu; menu offers installable versions discovered from current apt metadata)
- `--include-common yes|no` (default `yes`)
- `--confirm yes` (required outside menu when installation is needed)

Behavior:
- ensures the `ondrej/php` repository is available
- installs PHP CLI/FPM and the standard common extension set when requested
- validates `php-fpm`
- enables and starts `php<version>-fpm`

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh php install --php 8.3 --confirm yes
```

Notes:
- `site add` and `site set-php` can offer to install a missing version from the menu flow.
- The install picker is dynamic: it reads installable PHP versions from current apt metadata instead of a hardcoded version list.
- This section is intentionally small; per-site PHP behavior is handled by `site set-php`, `site fix`, and `site php-ini-*`.
