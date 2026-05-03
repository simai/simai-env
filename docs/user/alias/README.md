# Alias Profile

Use `alias` when a new domain should point to an existing site.

## Typical Menu Flow

```text
Sites -> Create site
SSL -> Issue Let's Encrypt
Sites -> Site info
```

## What Is Automatic

- nginx alias config
- no separate PHP-FPM pool
- no separate DB
- no separate project files

## What You Do Manually

Manage application files, PHP, cron, and DB on the target site, not on the alias.

Use this profile for domain aliases, not for separate projects.
