# Profile Workflows

The profile is the site type. It changes which files are created, whether PHP/DB/cron are needed, and which application actions appear under `Applications`.

Use this guide when the menu asks for a profile during:

```text
Sites -> Create site
```

## Quick Rule

| Profile | Use For | Continue In |
|---|---|---|
| `generic` | Simple PHP site without CMS-specific automation. | [Generic PHP](generic/README.md) |
| `static` | Static HTML/files, no PHP, no DB, no cron. | [Static](static/README.md) |
| `alias` | Extra domain pointing to an existing site. | [Alias](alias/README.md) |
| `laravel` | Laravel project with Composer, `.env`, scheduler, and queue worker. | [Laravel](laravel/README.md) |
| `wordpress` | WordPress site with WP-CLI, installer readiness, cron, and cache actions. | [WordPress](wordpress/README.md) |
| `bitrix` | 1C-Bitrix site with Bitrix nginx routing, PHP baseline, cron agents, cache, restore, and ownership checks. | [Bitrix](bitrix/README.md) |

## What Site Creation Does

`Sites -> Create site` creates the infrastructure layer:

- project directory under `/home/simai/www/<domain>`
- nginx config
- PHP-FPM pool when the profile needs PHP
- healthcheck
- optional SSL
- optional managed DB/user
- managed cron file when the profile supports cron

It does not always complete the application itself. For Laravel, WordPress, and Bitrix there is a second step after the application is real or after the browser installer has finished.

## Common Menu Route

After creating any site:

```text
Sites -> Site info
Diagnostics -> Site health check
```

For CMS/framework sites, also open the matching submenu:

```text
Applications -> Laravel
Applications -> WordPress
Applications -> Bitrix
```

## Profile-Specific Next Steps

- For plain PHP deployment, use [Generic PHP](generic/README.md).
- For static files, use [Static](static/README.md).
- For domain aliases, use [Alias](alias/README.md).
- For Laravel, use [Laravel](laravel/README.md).
- For WordPress, use [WordPress](wordpress/README.md).
- For Bitrix, use [Bitrix](bitrix/README.md).
