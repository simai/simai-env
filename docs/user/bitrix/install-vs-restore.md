# Bitrix Install Vs Restore

After `Sites -> Create site`, Bitrix still needs an application setup step.

There are two normal paths:

- fresh install: new Bitrix distribution and browser installer
- restore from backup: existing Bitrix archive through `restore.php`

Do not mix these paths in one directory unless you know exactly what will be overwritten.

## Decision Rule

Use fresh install when:

- this is a new Bitrix project
- there is no production archive to restore
- you want the standard Bitrix installer flow

Use restore when:

- you have an existing Bitrix backup archive
- the site already has real data
- the task is migration from another server or hosting

## Fresh Install

Typical menu flow:

```text
Sites -> Create site
Applications -> Bitrix -> Bitrix status
Applications -> Bitrix -> Bitrix installer ready
Open the installer URL in the browser
Complete the Bitrix installer
Applications -> Bitrix -> Bitrix complete setup
Applications -> Bitrix -> Bitrix status
Diagnostics -> Site health check
```

CLI equivalent:

```bash
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix installer-ready --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix finalize --domain <domain> --confirm yes
```

What `installer-ready` prepares:

- Bitrix DB config files from managed `db.env` when DB exists
- `bitrixsetup.php` as best-effort helper
- local Bitrix Site Management distribution archive
- unpacked installer files by default
- browser URL for the installer

The regular Bitrix web installer still runs in the browser.

## Restore From Backup

Typical menu flow:

```text
Sites -> Create site
Applications -> Bitrix -> Bitrix restore from backup
Open restore.php in the browser
Complete the restore wizard
Applications -> Bitrix -> Bitrix complete setup
Applications -> Bitrix -> Bitrix status
Diagnostics -> Site health check
```

CLI equivalent:

```bash
sudo /root/simai-env/simai-admin.sh bitrix restore-ready --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix finalize --domain <domain> --confirm yes
```

What `restore-ready` prepares:

- `public/restore.php`
- restore-sensitive write permissions
- optional DB preseed files when managed DB credentials are available
- browser restore URL
- post-restore finalize command

The Bitrix restore wizard still runs in the browser. It may unpack files, restore database content, and change application configuration.

## When The Site Already Has Files

If the docroot already contains a previous CMS or another Bitrix installation, stop and decide which state is authoritative.

Safe choices:

- create a new empty site path and restore into it
- make a manual backup before overwriting anything
- use `site info` and `site doctor` to inspect current infrastructure

Do not run fresh installer over a restored production directory unless the goal is to replace it.

## After Fresh Install Or Restore

Run `Bitrix complete setup` or CLI finalize:

```bash
sudo /root/simai-env/simai-admin.sh bitrix finalize --domain <domain> --confirm yes
```

Finalize is the post-install baseline. It verifies that Bitrix is installed, applies PHP baseline, and syncs agents to cron.

Then check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

## Successful Result

For a ready Bitrix site:

- browser installer or restore wizard is complete
- `bitrix status` reports installed web state
- `bitrix agents-status` reports agents via scheduler ready
- `site doctor` has `FAIL 0`
- ownership check has no root-owned files that block web operations

Warnings in `site doctor` can be acceptable, but read them before handing the site to users.
