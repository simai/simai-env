# self commands

Run with `sudo /root/simai-env/simai-admin.sh self <command> [options]` or via the `System` menu.

This group covers:
- platform status
- updates and bootstrap/repair
- automatic update checks
- automatic optimization
- shared scheduler jobs
- server-wide optimization baselines

## status
Show the main system summary.

Output includes:
- install dir
- OS and whether it is supported
- nginx / mysql / redis service state
- fail2ban service state and managed sshd jail presence
- php-fpm versions and CLI PHP
- component versions
- certbot timer state

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self status
```

## platform-status
Show the deeper platform diagnostics view.

Output includes:
- nginx state and `nginx -t`
- mysql / redis state
- active php-fpm units
- free disk space
- free inodes
- memory summary
- certbot timer

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self platform-status
```

## update
Update the installed `simai-env` tree in place.

Behavior:
- resolves the configured update ref
- downloads the exact target revision when `git` can resolve it to a commit SHA
- refuses non-official update repositories by default; use `SIMAI_UPDATE_ALLOW_CUSTOM_REPO=yes` only for a GitHub fork you explicitly trust
- refuses unresolved ref tarball fallback by default; use `SIMAI_UPDATE_ALLOW_UNRESOLVED_REF=yes` only when `git`/network SHA resolution is intentionally unavailable
- validates archive paths and entry types before extracting the update payload
- runs the updater from a temporary snapshot so the script is not overwritten while it is still executing
- creates a best-effort pre-update backup in `/root/simai-backups/`
- runs a fast post-update smoke check
- reloads the menu automatically when the command is run from menu mode

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self update
```

## supply-chain-doctor
Run a read-only check of self-update/install supply-chain guardrails.

Checks include:
- configured update ref syntax
- update repository allowlist state
- `git` availability for SHA-pinned updates
- whether the configured ref resolves to a commit SHA
- whether custom-repo or unresolved-ref escape hatches are enabled
- whether archive validation helpers are loaded

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self supply-chain-doctor
```

## sudo-admin-ensure
Create or repair a non-root sudo admin user for operator login.

Options:
- `--login <login>` (default `simai-admin`)
- `--copy-root-keys yes|no` (default `yes`) — copy `/root/.ssh/authorized_keys` when no explicit key file is provided.
- `--authorized-keys-file <path>` — use a regular file with authorized SSH keys.
- `--nopasswd yes|no` (default `yes`) — write a managed sudoers file with or without `NOPASSWD`.
- `--confirm yes` — required because this modifies users, SSH keys, and sudoers.

Behavior:
- creates a normal shell user if missing
- adds the user to the `sudo` group
- installs SSH `authorized_keys` with `0700/0600` permissions
- writes `/etc/sudoers.d/90-simai-admin-<login>`
- validates sudoers with `visudo -cf`
- validates `sshd -t` when sshd is available
- does not disable root SSH; do that only after the new user login has been tested

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self sudo-admin-ensure --login simai-admin --copy-root-keys yes --confirm yes
ssh simai-admin@<server>
sudo -n /root/simai-env/simai-admin.sh self sudo-admin-doctor --login simai-admin
```

## sudo-admin-doctor
Read-only readiness check for a non-root sudo admin user.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self sudo-admin-doctor --login simai-admin
```

## ssh-hardening-ensure
Apply the recommended operational-safe SSH hardening profile.

This profile is intentionally not the most restrictive possible model. It keeps
root SSH available as a key-only break-glass path, disables password and
keyboard-interactive SSH login, and keeps normal work on the non-root sudo admin
account.

Behavior:
- writes `/etc/ssh/sshd_config.d/01-simai-hardening.conf`
- sets `PermitRootLogin prohibit-password`
- sets `PasswordAuthentication no`
- sets `KbdInteractiveAuthentication no`
- sets `PubkeyAuthentication yes`
- validates `sshd -t`
- reloads ssh/sshd if syntax is valid

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self sudo-admin-ensure --login simai-admin --copy-root-keys yes --confirm yes
ssh simai-admin@<server>
sudo -n /root/simai-env/simai-admin.sh self ssh-hardening-ensure --confirm yes
```

## ssh-hardening-doctor
Read-only check for the operational-safe SSH profile.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self ssh-hardening-doctor
```

## version
Show local version, remote version, and update status.

Behavior:
- runs a live remote version check
- refreshes the cached automatic update state used by the menu banner

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self version
```

## auto-update-status
Show the current automatic update mode and cached remote version state.

Output includes:
- mode (`off`, `check`, `apply-safe`)
- check interval
- configured update ref
- local version
- cached remote version
- cached status
- last check time

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self auto-update-status
```

## auto-update-enable-check / auto-update-enable-apply / auto-update-disable
Control automatic update behavior.

Behavior:
- `auto-update-enable-check` turns on periodic update checks only
- `auto-update-enable-apply` enables menu-driven safe auto-apply
- `auto-update-disable` turns off automatic checks
- settings are stored in `/etc/simai-env.conf`

Safe auto-apply behavior:
- updates are applied only at safe menu points
- never during prompt chains or while a command is running
- after update, the menu reopens the same section

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self auto-update-enable-check
sudo /root/simai-env/simai-admin.sh self auto-update-enable-apply
sudo /root/simai-env/simai-admin.sh self auto-update-disable
```

## auto-update-run-check
Run one update check immediately and refresh the cached state used by the menu.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self auto-update-run-check
```

## bootstrap
Repair or install the base stack.

Options:
- `--php <version>` (default `8.2`)
- `--mysql <mysql|mariadb>` (default `mysql`)
- `--node-version <version>` (default `20`)

Behavior:
- installs/repairs base packages
- installs/enables the managed fail2ban SSH jail (`/etc/fail2ban/jail.d/simai-sshd.local`)
- installs the PHP Redis extension with the managed PHP stack so Laravel cache/session/queue setups have the expected extension available
- refreshes shared platform services
- installs `wp-cli` best-effort
- initializes profile activation defaults

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self bootstrap --php 8.3
```

## auto-optimize-status
Show the simple user-facing global automatic optimization state.

Output includes:
- whether automatic optimization is on
- mode
- interval
- cooldown
- batch size
- rebalance policy
- last run / last action / last summary

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self auto-optimize-status
```

## auto-optimize-enable / auto-optimize-disable
Turn automatic optimization on or off globally without removing the shared scheduler infrastructure.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self auto-optimize-enable
sudo /root/simai-env/simai-admin.sh self auto-optimize-disable
```

## health-review-status
Show the latest recurring platform review summary produced by the shared scheduler.

Output includes:
- total / active / suspended sites
- sites excluded from automatic optimization
- sites that still need setup
- sites with SSL expiring soon
- sites without SSL
- current FPM child pressure
- highlighted domains from the latest review

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self health-review-status
```

## site-review-status
Show the latest recurring site review summary produced by the shared scheduler.

Output includes:
- sites that still need setup
- sites that have stayed in setup longer than the configured threshold
- active rarely-used sites that are good pause candidates
- already paused sites
- sites in manual optimization mode

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self site-review-status
```

## scheduler
Run one shared scheduler tick immediately.

This is the same entrypoint used by `/etc/cron.d/simai-scheduler`.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self scheduler
```

## scheduler-status
Show the internal shared scheduler state.

Output includes:
- whether the shared cron entry is installed
- the exact scheduler command
- all built-in jobs
- each job's mode, interval, cooldown, next due time, last run, and last message

Current built-in jobs:
- `auto_optimize`
- `health_review`
- `site_review`

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self scheduler-status
```

## scheduler-enable / scheduler-disable
Enable or disable the whole shared scheduler, or a specific job, without changing the cron entry itself.

Options:
- `--job all|auto-optimize|health-review|site-review`

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self scheduler-disable --job auto-optimize
sudo /root/simai-env/simai-admin.sh self scheduler-enable --job health-review
sudo /root/simai-env/simai-admin.sh self scheduler-enable --job site-review
```

## scheduler-run
Run one scheduler job immediately for testing or debugging.

Options:
- `--job auto-optimize|health-review|site-review`

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self scheduler-run --job health-review
sudo /root/simai-env/simai-admin.sh self scheduler-run --job site-review
```

## perf-status
Show the current server-wide optimization status.

Output includes:
- detected server size
- recommended preset
- active preset
- default future site pool settings
- live FPM pressure
- nginx snippet/config state
- MySQL signals
- Redis signals

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self perf-status
```

## perf-plan
Show the current optimization recommendation plan for the heaviest PHP-FPM pools.

Options:
- `--limit <n>` (default internal value when omitted)

Output includes:
- total configured children
- recommended budget
- oversubscription level
- top site pools with suggested target modes

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self perf-plan --limit 8
```

## perf-rebalance
Apply site-level pool reductions in controlled batches.

Options:
- `--limit <n>`
- `--mode auto|safe|parked`
- `--confirm yes`

Behavior:
- uses `site perf-tune` under the hood
- respects per-site `auto optimize` overrides when `--mode auto`
- is meant for operator use, not for ordinary day-to-day menu use

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self perf-rebalance --limit 5 --mode auto --confirm yes
```

## perf-apply
Apply a managed server baseline for future sites and shared services.

Options:
- `--preset small|medium|large`
- `--confirm yes`

Behavior:
- writes managed defaults to `/etc/simai-env.conf`
- applies PHP-FPM OPcache baseline
- applies managed nginx/MySQL/Redis snippets

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self perf-apply --preset small --confirm yes
```

## Notes
- The regular `System` menu intentionally shows simple labels such as `Platform status`, `Optimization status`, `Optimization plan`, and `Automatic optimization`.
- Scheduler internals and `Health review` remain in Advanced mode.
- Shared scheduler config lives in `/etc/simai-env.conf`, but ordinary users usually do not need to edit it manually.
