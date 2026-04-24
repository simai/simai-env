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
- Wildcard HTTPS can now use either:
  - `cloudflare` with a credentials file on the server
  - `manual`, where Certbot shows TXT records and the operator adds them by hand
- Before requesting a wildcard certificate, the menu now shows a preflight screen with:
  - the `A` records the user should create
  - a simple explanation of whether TXT verification is automatic or manual
  - `PASS/WARN/FAIL` checks for DNS, provider/plugin, and credentials readiness

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
- `Prepare site database`
- `Write DB credentials to project .env`
- `Rotate database password`

### Access
Use this section to manage delegated file access without giving out `root` or the main `simai` account.

Common actions:
- `List accesses`
- `Show access details`
- `Create project access`
- `Create global access`
- `Add SSH key`
- `Disable access`
- `Enable access`
- `Reset access password`
- `Remove access`

Notes:
- Access users are `SFTP`-only and do not receive shell access.
- Project access is isolated with `ChrootDirectory` and a bind mount.
- Project root must live under `WWW_ROOT`.
- On systemd hosts, a `.mount` unit is created to persist the bind mount across reboots.

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

Notes:
- The menu shows only compatible site settings archives for `Review archive` and `Preview import`.
- Platform pre-update backups are intentionally excluded from that picker.

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
- `Bitrix restore from backup`

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
- `Automatic updates`
- `Check for updates now`
- `Advanced mode`

Advanced mode also adds:
- `Turn update checks on`
- `Turn safe auto-update on`
- `Turn automatic updates off`
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
8. If the profile needs a database, choose whether to prepare a managed site database now or continue without DB setup.

Notes:
- `Serve all first-level subdomains too?` creates one site for both the main domain and `*.domain`.
- Menu-based site creation expects a new empty project directory. It will refuse to attach a new site profile to a non-empty path.
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

## Restore a Bitrix site from backup
1. Create the site with profile `bitrix`.
2. Open `Applications -> Bitrix restore from backup`.
3. Open the shown `restore.php` URL in the browser.
4. Complete the Bitrix restore wizard.
5. Open `Applications -> Bitrix complete setup`.
6. Open `Applications -> Bitrix status`.

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

## Automatic update checks
1. Open `System`.
2. Use `Automatic updates` to see whether the platform is in `off`, `check`, or `apply-safe` mode.
3. Use `Check for updates now` when you want to refresh the cached update status immediately.

Notes:
- The menu banner uses cached update state instead of doing a live network check every screen redraw.
- In `apply-safe` mode, the menu can apply an update only at safe points such as entering or returning to a section.
- The menu does not auto-update during prompt chains or while a command is already running.
- After a safe auto-update, the menu returns you to the same section.

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
