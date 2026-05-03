# Bitrix Diagnostics

Run diagnostics after creation, restore, SSL changes, PHP changes, cron setup, and ownership repair.

## Standard Checks

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
```

## Cron Agents

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```

## Ownership

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
```

## Readiness Signal

`FAIL 0` in `site doctor` is the main infrastructure readiness signal. Warnings may still be acceptable, but read them before handing the site to users.
