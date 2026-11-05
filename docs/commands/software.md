# software commands

Run with `sudo /root/simai-env/simai-admin.sh software <command> [options]`.

Use this group to see and update the server software simai-env manages: the
web server, databases, Redis, Node.js and tools, and the package updates of
the whole system. PHP versions have their own group (`php list`, `php
install`, `php update`, see `php.md`).

## list
Show the catalogue of server programs and the waiting system updates. The
apt index is as fresh as the last refresh (`software refresh`;
`index_age_seconds` says how old it is).

The catalogue (1.43.0): `nginx`, `apache`, `certbot`, `fail2ban`, `mysql`
(Percona, MySQL or MariaDB, whichever is installed), `postgresql`, `redis`,
`memcached`, `php` (managed in the `php` group), `node`, `composer`, `git`,
`imagemagick`, `jpegoptim`, `optipng`, `ffmpeg`, `supervisor`. Groups:
`web`, `security`, `databases`, `cache`, `languages`, `tools`.

`--output json` answers `simai-software/1`:

- `components [...]`, one per program:
  - `key` (also `name`), `title`, `purpose` (one line, English), `group`
  - `installed`, `package`, `version`, `candidate`, `update`, `service`,
    `active`, `state: running|stopped|installed|not_installed`
  - `can_install`, `can_update`, `can_remove`; `install_blocked` and
    `remove_blocked` are `null` or `{code, text}` with codes
    `required_by_env` (part of simai-env), `managed_elsewhere` (PHP),
    `installed`, `not_installed`, `unavailable` (not in the repositories),
    `used_by_sites` (with `sites`), `has_certificates` (with `count`)
  - `packages` (what install and remove act on), `php_extensions` (installed
    with it for every PHP-FPM version), `keeps` (paths removal keeps),
    `sites` (sites that need it: node, apache, postgresql, mysql), `how`
  - `installable`: the same as `can_install` (kept for older panels)
- `system {updates, security, packages [{name, from, to, security}],
  kept_back, reboot_required, reboot_packages, index_age_seconds}`.

```bash
sudo /root/simai-env/simai-admin.sh software list
```

## refresh
Refresh the apt index (`apt-get update`) so `software list` and `php list`
show updates published since the last refresh.

```bash
sudo /root/simai-env/simai-admin.sh software refresh --confirm yes
```

## update
Install the waiting package updates of the system.

Options:
- `--security-only yes|no` (default `no`): only updates from the security
  pocket
- `--confirm yes`: without it the command prints a plan with the waiting
  packages

Behavior:
- asks every site before the update and remembers the ones that answer
- refreshes the apt index and upgrades installed packages; no package is
  installed or removed besides the upgrades (`apt-get upgrade`, packages
  that need new dependencies stay `kept_back`); changed configuration files
  are kept
- tests the configuration of nginx and every PHP-FPM version
- asks the sites again (three tries); the command fails and names the sites
  that stopped answering, and a configuration that is rejected
- reports whether the server needs a reboot; it never reboots by itself

Packages cannot be rolled back. Take `backup data` of important sites first
when the list holds database server packages.

```bash
sudo /root/simai-env/simai-admin.sh software update --security-only yes --confirm yes
```

## install
Install a program from the catalogue, or update it when it is installed and
a newer version is waiting.

Options:
- `--name <key>` (required): `node`, `redis`, `postgresql`, `apache`,
  `certbot`, `fail2ban`, `memcached`, `imagemagick`, `jpegoptim`,
  `optipng`, `ffmpeg`, `supervisor`
- `--version <major>`: Node.js major version (default `22`) or PostgreSQL
  major version (another than the Ubuntu one adds the signed PGDG
  repository); other programs take no version
- `--confirm yes`: without it the command prints a plan

Behavior:
- programs from Ubuntu are installed with `apt-get install`, changed
  configuration files kept; their service is started; `redis`,
  `memcached` and `imagemagick` also get `php<ver>-redis`,
  `php<ver>-memcached`, `php<ver>-imagick` for every PHP-FPM version
- an installed program with an update waiting is upgraded alone
  (`--only-upgrade`)
- `apache`: listens on `127.0.0.1:8088` only; sites move to it with
  `site apache`
- `node`: Node.js from the NodeSource repository with its signing key pinned
  by fingerprint. There is one Node.js per server: changing the major version
  is refused while sites with the node profile exist, and names them
- `postgresql`: the same as `db pgsql-install`
- refused, with the reason, for what simai-env owns (`nginx`, `mysql`,
  `composer`, `git`), for PHP (use `php install`) and for what is installed
  with nothing to update

```bash
sudo /root/simai-env/simai-admin.sh software install --name redis --confirm yes
```

## remove
Remove a program (1.43.0).

Options:
- `--name <key>` (required): as for `install`
- `--confirm yes`: without it the command prints a plan

Behavior:
- `apt-get remove`: configuration and data stay (`keeps`), so installing it
  again picks them up; its PHP extensions go with it
- refused, with the reason and the sites, while sites need it (Node.js
  under node sites, Apache under sites in Apache mode, PostgreSQL under
  PostgreSQL sites), Certbot while it renews certificates, and for what
  simai-env owns
- refused when apt would also remove a package the server needs (nginx,
  PHP, database servers, SSH, Git, Certbot and the like)

```bash
sudo /root/simai-env/simai-admin.sh software remove --name memcached --confirm yes
```
