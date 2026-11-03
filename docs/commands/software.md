# software commands

Run with `sudo /root/simai-env/simai-admin.sh software <command> [options]`.

Use this group to see and update the server software simai-env manages: the
web server, databases, Redis, Node.js and tools, and the package updates of
the whole system. PHP versions have their own group (`php list`, `php
install`, `php update`, see `php.md`).

## list
Show the components and the waiting system updates. The apt index is as
fresh as the last refresh (`software refresh`; `index_age_seconds` says how
old it is).

`--output json` answers `simai-software/1`:

- `components [{name, package, installed, version, candidate, update,
  service, active, installable}]` for `nginx`, `mysql` (Percona, MySQL or
  MariaDB, whichever is installed), `postgresql`, `redis`, `node` (also
  `sites`: the sites with the node profile) and `certbot`. `installable`
  means `software install` can add it.
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
Install a component that is not on the server.

Options:
- `--name node|redis|postgresql` (required)
- `--version <major>`: Node.js major version (default `22`) or PostgreSQL
  major version (another than the Ubuntu one adds the signed PGDG
  repository); Redis takes no version
- `--confirm yes`: without it the command prints a plan

Behavior:
- `redis`: `redis-server` from Ubuntu, listening on localhost, and
  `php<ver>-redis` for every installed PHP-FPM version
- `node`: Node.js from the NodeSource repository with its signing key pinned
  by fingerprint. There is one Node.js per server: changing the major version
  is refused while sites with the node profile exist, and names them
- `postgresql`: the same as `db pgsql-install`

```bash
sudo /root/simai-env/simai-admin.sh software install --name redis --confirm yes
```
