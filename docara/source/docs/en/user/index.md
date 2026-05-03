---
extends: _core._layouts.documentation
section: content
title: User Guide
description: Operator documentation for the interactive simai-env menu and profile-specific workflows.
---

# User Guide

Start here when you work through the interactive admin menu:

```bash
sudo /root/simai-env/simai-admin.sh menu
```

## Start Here

- [Menu user guide](../guide/menu-user-guide): everyday menu sections and common actions.
- [Profile workflows](profile-workflows): which site profile to choose and where to continue.

## Profile Guides

- [Generic PHP](generic/): simple PHP site without CMS-specific automation.
- [Static](static/): HTML/CSS/JS site without PHP, DB, or cron.
- [Alias](alias/): additional domain pointing to an existing site.
- [Laravel](laravel/): Laravel project setup, scheduler, queue, and finalize flow.
- [WordPress](wordpress/): WordPress installer, cron, and finalize flow.
- [Bitrix](bitrix/): 1C-Bitrix and Bitrix24 box-style sites, including [troubleshooting](bitrix/troubleshooting).

## Standard Check After Site Work

After creating or changing a site, run:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

`FAIL 0` in `site doctor` is the main infrastructure readiness signal. Warnings may still be acceptable, but read them before handing the site to users.
