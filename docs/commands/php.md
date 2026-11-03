# php commands

Run with `sudo /root/simai-env/simai-admin.sh php <command> [options]` or via menu.

Use this group to manage PHP as software of the host: list, install and
remove versions, turn extensions on and off, install package updates, reload
PHP-FPM. Versions live side by side; a site moves to another one with
`site set-php`.

## list
List installed PHP versions: FPM state, the sites on each, waiting package
updates, and which versions apt can install. The apt index is as fresh as the
last `apt-get update` (`php update` refreshes it).

`--output json` answers `simai-php/1`: `native` (the version of this Ubuntu
release), `versions [{version, fpm_active, sites, native, cli_default,
package_version, updates, removable}]`, `installable [versions]`. A version
is `removable` when no site uses it and it is neither the system version nor
the `php` command.

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

## remove
Remove a PHP version (all its packages). Refused while a site uses it (the
message names the sites), for the system version of the Ubuntu release, and
for the version behind the `php` command.

```bash
sudo /root/simai-env/simai-admin.sh php remove --php 8.2 --confirm yes
```

## extension
Turn an extension on or off for PHP-FPM of one version and reload it.
Turning on installs `php<version>-<name>` when the extension is not there
yet. When PHP-FPM rejects the change, the previous state comes back.

- `--php <version>`, `--name <extension>`, `--enabled yes|no` (required)

```bash
sudo /root/simai-env/simai-admin.sh php extension --php 8.3 --name imagick --enabled yes --confirm yes
```

`php extensions --php X` lists what is on and what can be turned on.

## update
Install the package updates of one PHP version: fixes within the version
(8.3.6 to 8.3.7), never a new version. PHP-FPM is tested and restarted, and
the sites on that version are asked before and after; the command fails and
names the sites that stopped answering. Packages are not rolled back.

```bash
sudo /root/simai-env/simai-admin.sh php update --php 8.3 --confirm yes
```

A new version is installed next to the old one (`php install`), sites move one
by one (`site set-php`), and the old version is removed when it is free.

Notes:
- `site add` and `site set-php` can offer to install a missing version from the menu flow.
- The install picker is dynamic: it reads installable PHP versions from current apt metadata instead of a hardcoded version list.
- This section is intentionally small; per-site PHP behavior is handled by `site set-php`, `site fix`, and `site php-ini-*`.
