---
extends: _core._layouts.documentation
section: content
title: Readme
description: Readme
---

# WordPress Profile

Use `wordpress` for a WordPress site.

## Typical Menu Flow

```text
Sites -> Create site
Applications -> WordPress -> WordPress status
Applications -> WordPress -> WordPress installer ready
Open /wp-admin/install.php in the browser
Applications -> WordPress -> WordPress complete setup
Applications -> WordPress -> WordPress status
Diagnostics -> Site health check
```

## What Is Automatic During Site Creation

- nginx and PHP-FPM are created
- DB can be created
- WordPress-compatible nginx routing is used
- managed cron can be written by WordPress actions

## What You Do In The Browser

Complete the WordPress installer.

## What WordPress Complete Setup Does

After browser install, `WordPress complete setup`:

- applies WordPress baseline
- syncs WordPress cron
- prepares common operational checks

## CLI Equivalents

```bash
sudo /root/simai-env/simai-admin.sh wp status --domain <domain>
sudo /root/simai-env/simai-admin.sh wp installer-ready --domain <domain>
sudo /root/simai-env/simai-admin.sh wp finalize --domain <domain> --confirm yes
```
