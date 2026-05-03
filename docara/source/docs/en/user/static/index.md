---
extends: _core._layouts.documentation
section: content
title: Readme
description: Readme
---

# Static Profile

Use `static` for HTML/CSS/JS files that do not need PHP or MySQL.

## Typical Menu Flow

```text
Sites -> Create site
SSL -> Issue Let's Encrypt
Diagnostics -> Site health check
```

## What Is Automatic

- nginx config
- static healthcheck
- no PHP-FPM pool
- no DB prompts
- no cron

## What You Do Manually

Upload static files into the site public directory.

Do not use PHP, DB, queue, Laravel, WordPress, or Bitrix menu commands for this profile.
