---
extends: _core._layouts.documentation
section: content
title: Readme
description: Readme
---

# Generic PHP Profile

Use `generic` for a normal PHP site that is not managed as Laravel, WordPress, or Bitrix.

## Typical Menu Flow

```text
Sites -> Create site
Sites -> Site info
SSL -> Issue Let's Encrypt
Diagnostics -> Site health check
```

## What Is Automatic

- nginx and PHP-FPM are created
- compatible installed PHP versions are offered
- optional DB can be created
- healthcheck is installed

## What You Do Manually

- upload or deploy application files
- configure the application `.env` if needed
- manage application-specific cron yourself, unless it becomes a dedicated profile later

## Checks

```bash
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
```
