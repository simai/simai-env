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
- downloads the exact target revision
- creates a best-effort pre-update backup in `/root/simai-backups/`
- runs a fast post-update smoke check
- reloads the menu automatically when the command is run from menu mode

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh self update
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
