# Bitrix Diagnostics

Run diagnostics after creation, install, restore, SSL changes, PHP changes, cron setup, ownership repair, and before handing the site to users.

## Standard Menu Path

```text
Sites -> Site info
Applications -> Bitrix -> Bitrix status
Applications -> Bitrix -> Bitrix agents status
Diagnostics -> Site health check
```

Use the CLI commands below when you need exact output for support or repeatable checks.

## Infrastructure Checks

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

`site info` confirms the selected profile, project path, nginx config, PHP-FPM pool, DB status, SSL status, and cron file.

`site doctor` is the broad infrastructure readiness check.

Main readiness signal:

```text
FAIL 0
```

Warnings can be acceptable, but read them before handoff.

## Bitrix Application Checks

```bash
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
```

Use this to check:

- Bitrix web state
- required Bitrix files
- cron entry state
- nginx upload body limit
- Bitrix URL rewrite fallback
- static asset compression/cache hints

Expected after a successful install or restore:

```text
Web state: installed
```

If status still reports installer/placeholder state, finish the browser installer or restore wizard first.

## Cron Agents

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```

Healthy state:

```text
BX_CRONTAB: missing
BX_CRONTAB_SUPPORT: true
Scheduler entry (cron_events.php): yes
CLI short_open_tag: yes
Agents via scheduler: yes
```

If not ready, use [Agents on cron](agents-cron.md).

## Ownership

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
```

Repair when needed:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain> --apply yes --confirm yes
```

Use this after restore, module install/remove, manual root operations, or any case where Bitrix cannot write/delete files.

## Database

```bash
sudo /root/simai-env/simai-admin.sh site db-status --domain <domain>
```

Use this when installer/restore cannot connect to MySQL or after DB creation/rotation.

## SSL

```bash
sudo /root/simai-env/simai-admin.sh ssl status --domain <domain>
```

Use this after Let's Encrypt issuance, wildcard DNS changes, or renewals.

## Handoff Checklist

Before handing a Bitrix site to a developer or customer:

- `site info` shows `Profile: bitrix`
- browser opens the expected host
- Bitrix installer/restore is complete
- `bitrix status` reports installed state
- `bitrix agents-status` is ready or the decision to keep web agents is explicit
- `bitrix ownership` has no blocking root-owned files
- `site doctor` reports `FAIL 0`
- SSL status matches the intended launch state
- DB status matches the intended install/restore state

## Common Symptoms And Where To Go

- For the full symptom index, see [Troubleshooting](troubleshooting.md).
- Human-readable Bitrix URLs open wrong content: [Nginx routing](nginx-routing.md).
- Large PDF/upload fails with `Network error` or `413`: [Uploads](uploads.md).
- Modules cannot be deleted or updated: [Ownership](ownership.md).
- Agents are not running from cron: [Agents on cron](agents-cron.md).
- Wildcard HTTPS is unclear or fails DNS validation: [SSL](ssl.md).
