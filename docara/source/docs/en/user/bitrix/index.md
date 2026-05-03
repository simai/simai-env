---
extends: _core._layouts.documentation
section: content
title: Readme
description: Readme
---

# Bitrix Profile

Use `bitrix` for 1C-Bitrix Site Management or Bitrix24 box-style sites.

This section is for operators who work mainly through:

```bash
sudo /root/simai-env/simai-admin.sh menu
```

## Start A New Bitrix Site

Use this route for first launch:

1. Create infrastructure: [Create site](create-site.md).
2. Choose fresh install or restore: [Install vs restore](install-vs-restore.md).
3. Make sure DB choice matches the scenario: [Database](database.md).
4. Complete Bitrix browser installer or restore wizard.
5. Run `Bitrix complete setup`.
6. Verify the result: [Diagnostics](diagnostics.md).

## Common Operations

- [Agents on cron](agents-cron.md): move Bitrix agents from web hits to cron and verify scheduler readiness.
- [SSL](ssl.md): issue standard or wildcard HTTPS certificate.
- [Nginx routing](nginx-routing.md): check CHPU/SEF fallback, host variables, and wildcard host mode.
- [Uploads](uploads.md): diagnose `Network error`, `413 Request Entity Too Large`, and upload size limits.
- [Ownership](ownership.md): detect and repair root-owned files after restore, module operations, or manual file changes.
- [Diagnostics](diagnostics.md): run the standard handoff checks.

## Find By Symptom

Use [Troubleshooting](troubleshooting.md) when you know the symptom but not the command:

- site opens slowly on first request
- subdomain opens wrong host or wrong data
- HTTPS issue fails
- restore stops near the end
- FileInput shows `Network error`
- Bitrix module cannot be deleted
- CHPU/SEF page opens wrong content
- agents status is not ready
- `site doctor` has warnings but no failures

## What Site Creation Does Automatically

For the Bitrix profile, site creation prepares:

- Bitrix nginx routing through `/bitrix/urlrewrite.php`
- upload body limit for common Bitrix FileInput uploads
- CSS/JS static compression/cache headers
- PHP-FPM pool with Bitrix-required INI values
- optional managed DB/user
- managed cron file

## What Still Requires Post-Install Action

Site creation does not finish:

- Bitrix browser installation
- Bitrix restore wizard
- final PHP/cron/cache baseline after installation
- agents switch from web hits to cron

Run `Bitrix complete setup` after the Bitrix application is installed or restored. It applies the post-install baseline.
