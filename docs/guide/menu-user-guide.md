# Menu User Guide

This guide is for the person who mainly works through:

```bash
sudo /root/simai-env/simai-admin.sh menu
```

It focuses on the everyday menu flow, not on internal implementation details.

Fresh install defaults:
- new installs enable only the core profiles at first: `static`, `generic`, and `alias`
- additional profiles such as `wordpress`, `laravel`, and `bitrix` can be enabled later from `Advanced -> Profiles`
- bootstrap installs PHP `8.2` by default; install another version from the `PHP` section when needed

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
4. For CMS profiles, complete setup from the `Applications` section.

### SSL
Use this section to view certificate state and enable HTTPS.

Common actions:
- `List certificates`
- `Certificate status`
- `Issue Let's Encrypt`
- `Install custom certificate`
- `Renew certificate`
- `Disable HTTPS`

Notes:
- If a site was created with `Serve all first-level subdomains too? = yes`, the SSL screen can now request a wildcard certificate for the main domain plus `*.domain`.
- Current wildcard HTTPS support uses Cloudflare DNS challenge and needs a credentials file on the server.

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
- `Database server status`
- `Create database for site`
- `Write site database settings`
- `Rotate database password`

### Diagnostics
Use this section for read-only checks.

Common actions:
- `Site health check`
- `Configuration check`
- `Platform status`

### Logs
Use this section to inspect logs without searching paths manually.

Common actions:
- `Platform log`
- `Setup log`
- `Command audit log`
- `Website access log`
- `Website error log`
- `Certificate log`

### Backup / Migrate
Use this section when you need a safe export/import workflow for site config archives.

Common actions:
- `Export site settings`
- `Review archive`
- `Preview import`

### Applications
This section is the shared application/CMS area. It now opens into three submenus:
- `Laravel`
- `WordPress`
- `Bitrix`

Regular mode keeps only the most common actions in each submenu. Advanced mode shows installer, scheduler, cache, and maintenance commands.

Common Laravel actions inside `Applications -> Laravel`:
- `Laravel status`
- `Laravel prepare app`
- `Laravel complete setup`
- `Laravel worker status`
- `Laravel worker restart`
- `Laravel worker logs`
- `Laravel scheduler enable`
- `Laravel scheduler disable`

Common WordPress actions inside `Applications -> WordPress`:
- `WordPress status`
- `WordPress optimization`
- `WordPress complete setup`

Common Bitrix actions inside `Applications -> Bitrix`:
- `Bitrix status`
- `Bitrix optimization`
- `Bitrix complete setup`

### Profiles
Use this section to inspect and manage profile availability.

Common actions:
- `List profiles`
- `Profile usage summary`
- `Check profiles`
- `Turn profile on`
- `Turn profile off`

### System
Use this section for the platform itself.

Regular mode:
- `Platform status`
- `Optimization status`
- `Automatic optimization`
- `Optimization plan`
- `Repair platform`
- `Update simai-env`
- `Version`
- `Advanced mode`

Advanced mode also adds:
- `Apply optimization plan`
- `Automation scheduler status`
- `Health review`
- `Site review`

## Most common user scenarios

## Create a new site
1. Open `Sites -> Create site`.
2. Enter the domain.
3. Choose the profile.
4. Choose whether the site should also serve all first-level subdomains.
5. Choose activity class if asked.
6. If the profile supports PHP, choose one of the installed compatible PHP versions.
7. If you want HTTPS right away, choose SSL issuance when prompted.
8. If the profile needs a database, confirm DB creation.

Notes:
- `Serve all first-level subdomains too?` creates one site for both the main domain and `*.domain`.
- After creation, the summary prints the DNS records you need to add for the main domain and wildcard host.
- `Site info` repeats these DNS records later, so you do not need to remember them.
- Wildcard HTTPS for subdomains is a separate next step. The summary and `Site info` both show the Cloudflare DNS challenge command to use after DNS is ready.

## Finish a Laravel site
1. Create the site with profile `laravel`.
2. Open `Applications -> Laravel prepare app`.
3. Open `Applications -> Laravel complete setup`.
4. Open `Applications -> Laravel status`.

## Finish a WordPress site
1. Create the site with profile `wordpress`.
2. Open `Applications -> WordPress complete setup` only after the browser installer is finished.
3. Open `Applications -> WordPress status`.

## Finish a Bitrix site
1. Create the site with profile `bitrix`.
2. Prepare the installer if needed from Advanced mode.
3. Complete the web install in the browser.
4. Open `Applications -> Bitrix complete setup`.
5. Open `Applications -> Bitrix status`.

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
- Then the profile-specific status in the `Applications` section

## Where to read more
- Command reference: `/Users/rim/Documents/GitHub/simai-env/docs/commands/`
- Daily operator quickstart: `/Users/rim/Documents/GitHub/simai-env/docs/operations/daily-ops-quickstart.md`
- Profile runbooks:
  - `/Users/rim/Documents/GitHub/simai-env/docs/operations/bitrix-production-runbook.md`
  - `/Users/rim/Documents/GitHub/simai-env/docs/operations/wordpress-production-runbook.md`
  - `/Users/rim/Documents/GitHub/simai-env/docs/operations/laravel-production-runbook.md`
