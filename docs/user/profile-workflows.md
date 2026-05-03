# Profile Workflows for Users

This guide explains what to do after choosing a site profile in the menu.

Use it when you work through:

```bash
sudo /root/simai-env/simai-admin.sh menu
```

The profile is the site type. It changes which files are created, whether PHP/DB/cron are needed, and which application actions appear under `Applications`.

## Quick Rule

- `generic`: simple PHP site without CMS-specific automation.
- `static`: static HTML/files, no PHP, no DB, no cron.
- `alias`: extra domain pointing to an existing site.
- `laravel`: Laravel project with Composer, `.env`, scheduler, and queue worker.
- `wordpress`: WordPress site with WP-CLI, installer readiness, cron, and cache actions.
- `bitrix`: 1C-Bitrix site with Bitrix nginx routing, PHP baseline, cron agents, cache, restore, and ownership checks.

After creating any site, run:

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

## What Happens During Site Creation

`Sites -> Create site` creates the infrastructure layer:

- project directory under `/home/simai/www/<domain>`
- nginx config
- PHP-FPM pool when the profile needs PHP
- healthcheck
- optional SSL
- optional managed DB/user
- managed cron file when the profile supports cron

It does not always complete the application itself. For Laravel, WordPress, and Bitrix there is a second step after the application is real or after the browser installer has finished.

## generic

Use `generic` for a normal PHP site that is not managed as Laravel, WordPress, or Bitrix.

Typical menu flow:

```text
Sites -> Create site
Sites -> Site info
SSL -> Issue Let's Encrypt
Diagnostics -> Site health check
```

What is automatic:

- nginx and PHP-FPM are created
- compatible installed PHP versions are offered
- optional DB can be created
- healthcheck is installed

What you do manually:

- upload or deploy application files
- configure the application `.env` if needed
- manage application-specific cron yourself, unless it becomes a dedicated profile later

Normal checks:

```bash
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
```

## static

Use `static` for HTML/CSS/JS files that do not need PHP or MySQL.

Typical menu flow:

```text
Sites -> Create site
SSL -> Issue Let's Encrypt
Diagnostics -> Site health check
```

What is automatic:

- nginx config
- static healthcheck
- no PHP-FPM pool
- no DB prompts
- no cron

What you do manually:

- upload static files into the site public directory

Do not use PHP, DB, queue, Laravel, WordPress, or Bitrix menu commands for this profile.

## alias

Use `alias` when a new domain should point to an existing site.

Typical menu flow:

```text
Sites -> Create site
SSL -> Issue Let's Encrypt
Sites -> Site info
```

What is automatic:

- nginx alias config
- no separate PHP-FPM pool
- no separate DB
- no separate project files

What you do manually:

- manage application files, PHP, cron, and DB on the target site, not on the alias

Use this for domain aliases, not for separate projects.

## laravel

Use `laravel` when the site should become a real Laravel application.

Typical menu flow:

```text
Sites -> Create site
Applications -> Laravel -> Laravel status
Applications -> Laravel -> Laravel prepare app
Applications -> Laravel -> Laravel complete setup
Applications -> Laravel -> Laravel status
Diagnostics -> Site health check
```

What is automatic during site creation:

- nginx points to `public`
- PHP-FPM pool is created
- DB can be created
- scheduler/queue infrastructure is prepared according to the profile

What is not automatic until you run Laravel actions:

- real Laravel application bootstrap
- `APP_KEY`
- storage link
- migrations
- queue worker activation

Use `Laravel prepare app` after creating a placeholder Laravel site. Use `Laravel complete setup` after the application exists and DB settings are ready.

CLI equivalents:

```bash
sudo /root/simai-env/simai-admin.sh laravel status --domain <domain>
sudo /root/simai-env/simai-admin.sh laravel app-ready --domain <domain>
sudo /root/simai-env/simai-admin.sh laravel finalize --domain <domain> --confirm yes
```

## wordpress

Use `wordpress` for a WordPress site.

Typical menu flow:

```text
Sites -> Create site
Applications -> WordPress -> WordPress status
Applications -> WordPress -> WordPress installer ready
Open /wp-admin/install.php in the browser
Applications -> WordPress -> WordPress complete setup
Applications -> WordPress -> WordPress status
Diagnostics -> Site health check
```

What is automatic during site creation:

- nginx and PHP-FPM are created
- DB can be created
- WordPress-compatible nginx routing is used
- managed cron can be written by WordPress actions

What you do in the browser:

- complete the WordPress installer

What `WordPress complete setup` does after browser install:

- applies WordPress baseline
- syncs WordPress cron
- prepares common operational checks

CLI equivalents:

```bash
sudo /root/simai-env/simai-admin.sh wp status --domain <domain>
sudo /root/simai-env/simai-admin.sh wp installer-ready --domain <domain>
sudo /root/simai-env/simai-admin.sh wp finalize --domain <domain> --confirm yes
```

## bitrix

Use `bitrix` for 1C-Bitrix Site Management or Bitrix24 box-style sites.

Typical fresh install flow:

```text
Sites -> Create site
Applications -> Bitrix -> Bitrix status
Open the Bitrix installer in the browser
Applications -> Bitrix -> Bitrix complete setup
Applications -> Bitrix -> Bitrix status
Diagnostics -> Site health check
```

Typical restore flow:

```text
Sites -> Create site
Applications -> Bitrix -> Bitrix restore from backup
Open restore.php in the browser
Complete the restore wizard
Applications -> Bitrix -> Bitrix complete setup
Applications -> Bitrix -> Bitrix status
Diagnostics -> Site health check
```

What is automatic during site creation:

- Bitrix nginx routing uses `/bitrix/urlrewrite.php`
- upload body limit is set for Bitrix FileInput uploads
- CSS/JS static files are served with gzip/cache headers
- PHP-FPM pool is created with Bitrix-required INI values
- DB can be created
- managed cron file is created

What is not fully automatic at creation:

- Bitrix browser installation or restore
- final PHP/cron/cache baseline after installation
- agents switch from web hits to cron

Run `Bitrix complete setup` after the Bitrix application is installed or restored. It applies the post-install baseline.

### Bitrix Agents on Cron

New Bitrix sites get a managed cron file, but agents are switched to cron only after explicit post-install action.

Use the menu:

```text
Applications -> Bitrix -> Bitrix agents status
Applications -> Bitrix -> Sync agents to cron
```

Or use CLI:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain> --apply yes --confirm yes
```

Expected healthy state:

```text
BX_CRONTAB: missing
BX_CRONTAB_SUPPORT: true
Scheduler entry (cron_events.php): yes
CLI short_open_tag: yes
Agents via scheduler: yes
```

Why this is explicit:

- web installer/restore must finish first
- `dbconn.php` is modified, so the command creates a backup
- older Bitrix core files may require `php -d short_open_tag=1` in cron

### Bitrix Ownership

If modules, cache files, or restored files become `root:root`, Bitrix may fail to update or remove files later.

Check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
```

Repair:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain> --apply yes --confirm yes
```

`site doctor` also warns about root-owned files.

## What To Check After Any Profile-Specific Action

Use this sequence:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Then add the profile status command:

```bash
sudo /root/simai-env/simai-admin.sh laravel status --domain <domain>
sudo /root/simai-env/simai-admin.sh wp status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
```

For Bitrix cron agents:

```bash
sudo /root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```

`FAIL 0` in `site doctor` is the main infrastructure readiness signal. Warnings may still be acceptable, but read them before handing the site to users.
