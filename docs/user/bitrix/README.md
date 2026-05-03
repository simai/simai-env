# Bitrix Profile

Use `bitrix` for 1C-Bitrix Site Management or Bitrix24 box-style sites.

## Start Here

- [Create site](create-site.md): what the menu creates and what remains after creation.
- [Install vs restore](install-vs-restore.md): fresh installer and `restore.php` scenarios.
- [Agents on cron](agents-cron.md): move Bitrix agents from web hits to cron.
- [Ownership](ownership.md): detect and repair root-owned files.
- [Nginx routing](nginx-routing.md): Bitrix URL rewriting and nginx-specific request variables.
- [Uploads](uploads.md): file upload limits and `413 Request Entity Too Large`.
- [SSL](ssl.md): regular and wildcard HTTPS notes.
- [Database](database.md): managed DB and application credential notes.
- [Diagnostics](diagnostics.md): checks after install, restore, or runtime changes.

## First Launch Checklist

Use this route for a new operator flow:

1. Create infrastructure: [Create site](create-site.md).
2. Choose fresh install or restore: [Install vs restore](install-vs-restore.md).
3. Make sure DB choice matches the scenario: [Database](database.md).
4. Complete Bitrix browser installer or restore wizard.
5. Run `Bitrix complete setup`.
6. Verify the result: [Diagnostics](diagnostics.md).

## Typical Fresh Install Flow

```text
Sites -> Create site
Applications -> Bitrix -> Bitrix status
Open the Bitrix installer in the browser
Applications -> Bitrix -> Bitrix complete setup
Applications -> Bitrix -> Bitrix status
Diagnostics -> Site health check
```

## Typical Restore Flow

```text
Sites -> Create site
Applications -> Bitrix -> Bitrix restore from backup
Open restore.php in the browser
Complete the restore wizard
Applications -> Bitrix -> Bitrix complete setup
Applications -> Bitrix -> Bitrix status
Diagnostics -> Site health check
```

## What Is Automatic During Site Creation

- Bitrix nginx routing uses `/bitrix/urlrewrite.php`
- upload body limit is set for Bitrix FileInput uploads
- CSS/JS static files are served with gzip/cache headers
- PHP-FPM pool is created with Bitrix-required INI values
- DB can be created
- managed cron file is created

## What Is Not Fully Automatic At Creation

- Bitrix browser installation or restore
- final PHP/cron/cache baseline after installation
- agents switch from web hits to cron

Run `Bitrix complete setup` after the Bitrix application is installed or restored. It applies the post-install baseline.
