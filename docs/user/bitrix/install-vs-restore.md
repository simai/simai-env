# Bitrix Install Vs Restore

Bitrix sites have two common application setup paths after the infrastructure site is created.

## Fresh Install

Use this when you need a clean Bitrix installation.

Menu flow:

```text
Sites -> Create site
Applications -> Bitrix -> Bitrix status
Open the Bitrix installer in the browser
Applications -> Bitrix -> Bitrix complete setup
```

The environment prepares nginx, PHP-FPM, optional DB, healthcheck, and cron file. The Bitrix installer still runs in the browser.

## Restore From Backup

Use this when you have a Bitrix archive and need to restore through `restore.php`.

Menu flow:

```text
Sites -> Create site
Applications -> Bitrix -> Bitrix restore from backup
Open restore.php in the browser
Complete the restore wizard
Applications -> Bitrix -> Bitrix complete setup
```

After restore, run diagnostics and ownership checks. Restored archives can bring old file permissions, old DB settings, or old Bitrix runtime assumptions.

## After Either Path

Run:

```bash
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```
