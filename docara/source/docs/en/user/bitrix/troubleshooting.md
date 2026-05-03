---
extends: _core._layouts.documentation
section: content
title: Troubleshooting
description: Troubleshooting
---

# Bitrix Troubleshooting

Use this index when you know the symptom but not the right Bitrix guide.

Start with the standard checks:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

## Site Opens Slowly On First Request

Likely areas:

- PHP-FPM cold start or insufficient pool footprint
- Bitrix cache state
- nginx static compression/cache hints
- external services used by the application

Check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix perf-status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Read:

- [Diagnostics](diagnostics.md)
- [Nginx routing](nginx-routing.md)

If this is a production incident, measure response times before changing settings.

## Subdomain Opens Wrong Host Or Wrong Data

Likely areas:

- site was not created in wildcard host mode
- wildcard DNS record is missing
- application logic uses `SERVER_NAME` instead of exact `HTTP_HOST`
- wildcard SSL is missing even though wildcard host mode exists

Check:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
curl -I -H "Host: test.<domain>" http://127.0.0.1/
```

Read:

- [Create site](create-site.md)
- [Nginx routing](nginx-routing.md)
- [SSL](ssl.md)

## HTTPS Issue Fails

Likely areas:

- DNS does not point to the server
- wildcard site tries to issue standard SSL only
- wildcard certificate requested without DNS challenge
- Cloudflare token has insufficient permissions
- manual DNS challenge TXT record is missing or not propagated

Check:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh ssl status --domain <domain>
```

Read:

- [SSL](ssl.md)

For wildcard HTTPS, confirm:

```text
<domain> -> A -> <server-ip>
*.<domain> -> A -> <server-ip>
```

## Restore Stops Near The End

Likely areas:

- restored files cannot be written
- archive brings old ownership/permissions
- database credentials do not match restore plan
- disk or path layout differs from source server

Check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
sudo /root/simai-env/simai-admin.sh site db-status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Read:

- [Install vs restore](install-vs-restore.md)
- [Database](database.md)
- [Ownership](ownership.md)

## FileInput Shows Network Error

Likely areas:

- nginx rejects the body with `413 Request Entity Too Large`
- PHP upload limits are lower than the file size
- Bitrix field/module limit is lower than the file size

Check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Read:

- [Uploads](uploads.md)

If small files work and larger files fail with `413`, check nginx first.

## Bitrix Module Cannot Be Deleted Or Updated

Likely areas:

- module files are owned by `root`
- module cache/generated files are owned by `root`
- deployment or manual copy used the wrong Unix user

Check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
```

Repair:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain> --apply yes --confirm yes
```

Read:

- [Ownership](ownership.md)

## CHPU/SEF Page Opens Wrong Content

Likely areas:

- nginx fallback points to `/index.php`
- Bitrix route should go through `/bitrix/urlrewrite.php`
- site config was manually edited or regenerated with a generic template

Check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Read:

- [Nginx routing](nginx-routing.md)

Expected fallback:

```text
/bitrix/urlrewrite.php?$args
```

## Agents Status Is Not Ready

Likely areas:

- browser installer or restore wizard is not complete
- `dbconn.php` does not have cron support baseline
- managed cron entry is missing or old
- cron command lacks `short_open_tag=1`

Check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```

Apply:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain> --apply yes --confirm yes
```

Read:

- [Agents on cron](agents-cron.md)

## Site Doctor Has Warnings But No Failures

`FAIL 0` is the main infrastructure readiness signal. Warnings still matter, but they do not always block handoff.

Check what the warning is about:

- PHP recommended values: usually tune through Bitrix baseline/performance commands
- root-owned files: [Ownership](ownership.md)
- nginx Bitrix checks: [Nginx routing](nginx-routing.md) or [Uploads](uploads.md)
- cron/agents: [Agents on cron](agents-cron.md)
- SSL: [SSL](ssl.md)

Use:

```bash
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain> --strict yes
```

when you need a stricter pass/fail gate.

## Before Asking For Support

Collect:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

If the issue is cron:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```

If the issue is SSL:

```bash
sudo /root/simai-env/simai-admin.sh ssl status --domain <domain>
```

If the issue is file permissions:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
```
