# Menu User Guide

This guide is for the person who mainly works through:

```bash
sudo /root/simai-env/simai-admin.sh menu
```

It focuses on the everyday menu flow, not on internal implementation details.

## How the menu behaves
- The menu stays open after commands finish.
- Failed commands return you to the menu instead of dropping you to the shell.
- When a command needs required values such as `domain`, `file`, or `php`, the menu asks for them.
- Empty selection or cancel returns safely to the menu.
- `Advanced mode` lives inside `System`.

## Main sections

### Sites
Use this section when you need to create, inspect, pause, resume, or remove a site.

Common actions:
- `List sites`
- `Create site`
- `Site info`
- `Site activity`
- `Set activity`
- `Optimization override status`
- `Pause site`
- `Resume site`
- `Change site PHP`
- `Remove site`

Typical flow:
1. Create the site.
2. Open `Site info`.
3. If needed, issue SSL in the `SSL` section.
4. For CMS profiles, complete setup from the `Laravel` section.

### SSL
Use this section to view certificate state and enable HTTPS.

Common actions:
- `List SSL`
- `SSL status`
- `Issue Let's Encrypt`
- `Install custom certificate`
- `Renew certificate`
- `Remove SSL`

### PHP
Use this section when you need to inspect installed PHP versions, install a new version, or reload PHP-FPM.

Common actions:
- `List PHP versions`
- `Install PHP version`
- `Reload / restart PHP-FPM`

### Database
Use this section for database overview and site-level DB operations.

Common actions:
- `List databases`
- `MySQL status`
- `Create DB + user`
- `Write DB credentials to project`
- `Rotate DB password`

### Diagnostics
Use this section for read-only checks.

Common actions:
- `Site doctor`
- `Drift plan`
- `Platform status`

### Logs
Use this section to inspect logs without searching paths manually.

Common actions:
- `Admin log`
- `Environment log`
- `Audit log`
- `Nginx access log`
- `Nginx error log`
- `Let's Encrypt log`

### Backup / Migrate
Use this section when you need a safe export/import workflow for site config archives.

Common actions:
- `Export site config`
- `Inspect archive`
- `Import archive (plan)`

### Laravel
The menu label is currently `Laravel`, but this section is actually the shared application/CMS daily-ops area for:
- Laravel
- WordPress
- Bitrix

Regular mode keeps only the most common actions. Advanced mode shows installer/scheduler/cache maintenance commands.

Common Laravel actions:
- `Laravel status`
- `Laravel prepare app`
- `Laravel complete setup`
- `Worker status`
- `Worker restart`
- `Worker logs`
- `Enable scheduler`
- `Disable scheduler`

Common WordPress actions:
- `WordPress status`
- `WordPress optimization`
- `WordPress complete setup`

Common Bitrix actions:
- `Bitrix status`
- `Bitrix optimization`
- `Bitrix complete setup`

### Profiles
Use this section to inspect and manage profile availability.

Common actions:
- `List profiles`
- `Used by`
- `Validate profiles`
- `Enable profile`
- `Disable profile`

### System
Use this section for the platform itself.

Regular mode:
- `System status`
- `Optimization status`
- `Automatic optimization`
- `Optimization recommendations`
- `Repair environment`
- `Update simai-env`
- `Version`
- `Advanced mode`

Advanced mode also adds:
- `Apply optimization recommendations`
- `Scheduler status`
- `Health review`

## Most common user scenarios

## Create a new site
1. Open `Sites -> Create site`.
2. Enter the domain.
3. Choose the profile.
4. Choose activity class if asked.
5. If the profile needs a database, confirm DB creation.
6. If you want HTTPS right away, choose SSL issuance when prompted.

## Finish a Laravel site
1. Create the site with profile `laravel`.
2. Open `Laravel -> Laravel prepare app`.
3. Open `Laravel -> Laravel complete setup`.
4. Open `Laravel -> Laravel status`.

## Finish a WordPress site
1. Create the site with profile `wordpress`.
2. Open `Laravel -> WordPress complete setup` only after the browser installer is finished.
3. Open `Laravel -> WordPress status`.

## Finish a Bitrix site
1. Create the site with profile `bitrix`.
2. Prepare the installer if needed from Advanced mode.
3. Complete the web install in the browser.
4. Open `Laravel -> Bitrix complete setup`.
5. Open `Laravel -> Bitrix status`.

## Pause a rarely used site
1. Open `Sites -> Pause site`.
2. Confirm.
3. The site stays registered, but its runtime is parked behind a managed `503`.

To bring it back:
1. Open `Sites -> Resume site`.

## Turn automatic optimization on or off
1. Open `System`.
2. Use `Automatic optimization`.

Ordinary users normally do not need `Scheduler status`; it is kept in Advanced mode.

## If you are not sure what to do next
- Start with `Sites -> Site info`
- Then `Diagnostics -> Site doctor`
- Then `SSL -> SSL status`
- Then the profile-specific status in the `Laravel` section

## Where to read more
- Command reference: `/Users/rim/Documents/GitHub/simai-env/docs/commands/`
- Daily operator quickstart: `/Users/rim/Documents/GitHub/simai-env/docs/operations/daily-ops-quickstart.md`
- Profile runbooks:
  - `/Users/rim/Documents/GitHub/simai-env/docs/operations/bitrix-production-runbook.md`
  - `/Users/rim/Documents/GitHub/simai-env/docs/operations/wordpress-production-runbook.md`
  - `/Users/rim/Documents/GitHub/simai-env/docs/operations/laravel-production-runbook.md`
