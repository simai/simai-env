# User Documentation

Start here when you work through:

```bash
sudo /root/simai-env/simai-admin.sh menu
```

## Main Guides

- [Menu user guide](../guide/menu-user-guide.md): everyday menu sections and common actions.
- [Admin access model](admin-access.md): root key-only, optional `simai-admin`, runtime `simai`, and Access users.
- [Profile workflows](profile-workflows.md): which site profile to choose and where to continue.

## Profile Guides

- [Generic PHP](generic/README.md): simple PHP site without CMS-specific automation.
- [Static](static/README.md): HTML/CSS/JS site without PHP, DB, or cron.
- [Alias](alias/README.md): additional domain pointing to an existing site.
- [Laravel](laravel/README.md): Laravel project setup, scheduler, queue, and finalize flow.
- [WordPress](wordpress/README.md): WordPress installer, cron, and finalize flow.
- [Bitrix](bitrix/README.md): 1C-Bitrix and Bitrix24 box-style sites, including [troubleshooting](bitrix/troubleshooting.md).

## Standard Check After Site Work

After creating or changing a site, run:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

`FAIL 0` in `site doctor` is the main infrastructure readiness signal. Warnings may still be acceptable, but read them before handing the site to users.
