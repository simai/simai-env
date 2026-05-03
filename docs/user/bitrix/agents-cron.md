# Bitrix Agents On Cron

Bitrix agents are scheduled application jobs. By default, many Bitrix installations can run agents from web hits. For production sites, it is usually better to run them from cron so visitors do not trigger background work.

New Bitrix sites get a managed cron file, but agents are switched to cron only after explicit post-install action.

## When To Use This

Use this guide after:

- fresh Bitrix browser installer is complete
- restore through `restore.php` is complete
- PHP version was changed for the site
- `site doctor` or `bitrix status` shows cron/agents warnings
- you need to verify that agents are no longer driven by web requests

Do not apply agents sync before the Bitrix application is installed or restored. The command changes Bitrix config files and expects a real `dbconn.php`.

## Menu Flow

First inspect:

```text
Applications -> Bitrix -> Bitrix agents status
```

Then apply:

```text
Applications -> Bitrix -> Sync agents to cron
```

Then verify again:

```text
Applications -> Bitrix -> Bitrix agents status
Applications -> Bitrix -> Bitrix cron status
```

`Bitrix complete setup` also applies agents sync after the web installer/restore has finished.

## CLI Flow

Plan only:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain>
```

Apply:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain> --apply yes --confirm yes
```

Verify:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```

## What The Sync Changes

`agents-sync --apply yes` does two things:

1. Rewrites the managed cron entry so it runs:

```text
php -d short_open_tag=1 public/bitrix/modules/main/tools/cron_events.php
```

2. Normalizes `public/bitrix/php_interface/dbconn.php`:

```text
BX_CRONTAB: removed
BX_CRONTAB_SUPPORT: true
```

The command creates a backup before changing `dbconn.php`:

```text
dbconn.php.bak.<timestamp>
```

## Expected Healthy State

Healthy `agents-status` output should show:

```text
BX_CRONTAB: missing
BX_CRONTAB_SUPPORT: true
Scheduler file: managed
Scheduler domain marker: yes
Scheduler slug marker: yes
Scheduler entry (cron_events.php): yes
CLI short_open_tag: yes
Agents via scheduler: yes
```

The exact label can vary slightly by version, but the meaning should match this block.

## What The Status Fields Mean

`BX_CRONTAB: missing`

This is expected. It means the web request is not pretending to be cron.

`BX_CRONTAB_SUPPORT: true`

This tells Bitrix that cron mode is supported.

`Scheduler entry (cron_events.php): yes`

The system cron file contains the Bitrix cron entry.

`CLI short_open_tag: yes`

The cron command explicitly enables `short_open_tag=1`. This is important for old Bitrix core files that still contain short PHP tags. Without this flag, manual or system cron can fail with PHP parse errors before Bitrix agents run.

`Agents via scheduler: yes`

This is the combined readiness result.

## Managed Cron File Vs Agents Mode

These are different states:

- `cron-sync` rewrites the managed cron file.
- `agents-sync` rewrites the cron file and updates Bitrix `dbconn.php` constants.

A site can have a correct cron file and still not have Bitrix agents switched to cron. Use `agents-status` for the final answer, not only `cron-status`.

## After Restore

Run agents sync again after restore. A restored archive can bring an old `dbconn.php` that does not match the environment baseline.

Recommended sequence:

```bash
sudo /root/simai-env/simai-admin.sh bitrix restore-ready --domain <domain>
# complete restore.php in browser
sudo /root/simai-env/simai-admin.sh bitrix finalize --domain <domain> --confirm yes
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
```

## After PHP Version Change

Changing site PHP can recreate PHP-FPM pool and related runtime files. The managed cron command should continue using the selected PHP binary, but verify it:

```bash
sudo /root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
```

If `CLI short_open_tag` or scheduler entry is not ready, apply agents sync again.

## Troubleshooting

If `BX_CRONTAB_SUPPORT` is not `true`, run:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain> --apply yes --confirm yes
```

If `Scheduler entry (cron_events.php)` is `no`, run the same agents sync. It refreshes the managed cron file.

If `CLI short_open_tag` is `no`, the cron entry is old or manually edited. Run agents sync to rewrite it.

If the command says the site is still in installer mode, finish the browser installer or restore wizard first, then run:

```bash
sudo /root/simai-env/simai-admin.sh bitrix finalize --domain <domain> --confirm yes
```

If cron looks ready but jobs do not run, check system cron and logs:

```bash
sudo systemctl status cron
sudo grep CRON /var/log/syslog | tail -50
```

## Handoff Checklist

Before saying that Bitrix agents are on cron:

- `bitrix agents-status` reports agents via scheduler ready
- `bitrix cron-status` reports managed cron entry
- `CLI short_open_tag` is `yes`
- `dbconn.php.bak.<timestamp>` exists after the first apply
- `site doctor` has no cron-related failure
