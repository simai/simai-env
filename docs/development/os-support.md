# Operating system support

## Supported

| Release | PHP | Database | PostgreSQL | Node.js | Notes |
| --- | --- | --- | --- | --- | --- |
| Ubuntu 22.04 (jammy) | 8.1 native, others from ondrej/php | MySQL 8.0 / Percona 8.0 | 14 native, PGDG | NodeSource | |
| Ubuntu 24.04 (noble) | 8.3 native, others from ondrej/php | MySQL 8.0 / Percona 8.0 | 16 native, PGDG | NodeSource | |
| Ubuntu 26.04 (resolute) | 8.5 native only | MySQL 8.4 / Percona 8.0 | 18 native, PGDG | NodeSource (22 also native) | ondrej/php has no packages yet |

`lib/platform.sh` decides support and the native PHP version. When
ondrej/php starts publishing for 26.04, `platform_ondrej_php_available`
detects it and other PHP versions become installable without a code change.
Every release runs CI and the container suite (`testing/containers`) on all
three.

## Candidates

Checked on 2026-10-19 with the official images and vendor repositories.

### Debian 12 (bookworm) and Debian 13 (trixie): recommended next

Same apt, systemd and nginx/PHP-FPM layout as Ubuntu
(`/etc/nginx/sites-available`, `/etc/php/<ver>/fpm/pool.d`), so profiles,
pools, cron, units and backups work unchanged.

| | Debian 12 | Debian 13 |
| --- | --- | --- |
| PHP native | 8.2 | 8.4 |
| other PHP | packages.sury.org (same maintainer as ondrej/php) | packages.sury.org |
| MySQL | not in Debian; Percona and repo.mysql.com publish for it | same |
| MariaDB | 10.11 | 11.8 |
| PostgreSQL | 15 native, PGDG | 17 native, PGDG |
| Node.js | 18 native, NodeSource | 20 native, NodeSource |
| Python | 3.11 | 3.13 |

Work needed (about one release):

- PHP repository: sury.org with a fingerprint-pinned key instead of
  `add-apt-repository ppa:ondrej/php` (no PPAs on Debian);
- database default: Percona 8.0 (already used by `install.sh`) or MariaDB;
  `db_utils.sh` already treats `mariadb` as MySQL-compatible, but site
  database creation, `db network-*` and backups need a MariaDB pass;
- `platform.sh`: support matrix, native versions; `pgsql_ubuntu_major`
  becomes a per-distribution table;
- a Debian image for the container suite and a CI job (GitHub has no Debian
  runners; run CI in a `debian:12`/`debian:13` container).

### Ubuntu interim releases (25.10 and later non-LTS)

Not recommended: nine months of support, and third-party repositories
(ondrej/php, Percona) often skip them.

### RHEL family (AlmaLinux, Rocky Linux 9/10)

Not close: dnf, `/etc/nginx/conf.d`, PHP from Remi with a different pool
layout, SELinux contexts for site directories and sockets, firewalld instead
of ufw. Supporting it means an OS adapter layer for packages, paths,
services and security labels: several releases of work. Hosts that need it
today (for example an old FASTPANEL server on AlmaLinux 8) are better
migrated to a supported Ubuntu or Debian host.
