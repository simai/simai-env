# Bitrix Agents On Cron

New Bitrix sites get a managed cron file, but agents are switched to cron only after explicit post-install action.

Use the menu:

```text
Applications -> Bitrix -> Bitrix agents status
Applications -> Bitrix -> Sync agents to cron
```

Or use CLI:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain> --apply yes --confirm yes
```

## Expected Healthy State

```text
BX_CRONTAB: missing
BX_CRONTAB_SUPPORT: true
Scheduler entry (cron_events.php): yes
CLI short_open_tag: yes
Agents via scheduler: yes
```

## Why This Is Explicit

- web installer/restore must finish first
- `dbconn.php` is modified, so the command creates a backup
- older Bitrix core files may require `php -d short_open_tag=1` in cron

## After Sync

Run:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```
