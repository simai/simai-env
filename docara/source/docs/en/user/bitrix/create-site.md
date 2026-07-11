---
extends: _core._layouts.documentation
section: content
title: Create Site
description: Create Site
---

# Create Bitrix Site

Use this guide when choosing the `bitrix` profile in:

```text
Sites -> Create site
```

`Sites -> Create site` creates the infrastructure layer. It does not complete the Bitrix browser installer and does not restore a Bitrix archive by itself.

## Before You Start

Prepare these values:

- main domain, for example `example.ru`
- whether first-level subdomains must open the same Bitrix site
- target PHP version already installed on the server
- decision about database setup: managed new DB or migration without DB creation
- SSL decision: issue now or later
- for wildcard SSL: DNS access or Cloudflare API token

If you are restoring an existing Bitrix site, also prepare the archive and database plan before creating the site.

## Menu Flow

```text
Sites -> Create site
domain: <domain>
Select profile -> bitrix
Serve all first-level subdomains too? -> no|yes
Select site activity -> standard|high-traffic|rarely-used
Select PHP version -> installed compatible PHP version
Database setup for this site -> create-managed-db|continue-without-db
Issue Let's Encrypt certificate after site creation? -> no|yes
```

The exact prompt order can vary slightly by version and current server state.

## Domain Mode

Choose standard mode when only the main domain should open this site:

```text
example.ru
```

Choose wildcard/subdomain mode when the same Bitrix installation should serve the main domain and first-level subdomains:

```text
example.ru
*.example.ru
```

In menu terms this is:

```text
Serve all first-level subdomains too? -> yes
```

Use wildcard mode for multi-domain/subdomain Bitrix projects when application code expects requests from hosts such as `camp.example.ru`, `test.example.ru`, or `b24.example.ru` to reach the same project root.

For wildcard HTTPS, continue with [SSL](ssl.md).

## Activity Class

The activity class is the user-facing performance intent:

- `standard`: normal site, balanced default
- `high-traffic`: active project with higher PHP-FPM footprint
- `rarely-used`: low-traffic or parked project with lower resource footprint

You can change this later from:

```text
Sites -> Change activity class
```

## Database Choice

For a fresh Bitrix install, choose managed DB unless you have a specific reason not to:

```text
Database setup for this site -> create-managed-db
```

For a restore or migration where the database already exists, choose:

```text
Database setup for this site -> continue-without-db
```

Then connect or restore the database through the matching migration flow. Do not recreate a database that already contains production data.

See [Database](database.md).

## SSL Choice During Creation

For a single-domain site, issuing SSL during creation is usually fine when DNS already points to the server.

For a wildcard/subdomain site, it is often clearer to answer `no` during creation and issue SSL from the SSL menu after DNS and wildcard validation are ready:

```text
SSL -> Issue Let's Encrypt
```

See [SSL](ssl.md).

## What The Environment Creates

For the Bitrix profile, site creation prepares:

- project directory under `/home/simai/www/<domain>`
- Bitrix-oriented nginx config
- PHP-FPM pool
- local healthcheck
- optional managed DB/user
- managed cron file
- Bitrix-friendly upload body limit
- nginx fallback for Bitrix URL rewriting

## What It Does Not Finish

Site creation does not finish:

- Bitrix browser installation
- Bitrix restore wizard
- final PHP/cron/cache baseline after installation
- switching Bitrix agents from web hits to cron

After site creation, continue with [Install vs restore](install-vs-restore.md).

## If The Directory Already Has Files

The regular menu flow expects a new empty project directory. This is intentional: reusing a non-empty path can silently mix two applications.

If you need to attach an existing directory, use a deliberate CLI flow and inspect the path first. For ordinary user work, create a new site path and restore/deploy into it.

## CLI Equivalent

Single-domain fresh install with managed DB:

```bash
sudo /root/simai-env/simai-admin.sh site add \
  --domain <domain> \
  --profile bitrix \
  --php 8.2 \
  --create-db yes
```

By default this creates infrastructure only and does not place public
`bitrixsetup.php` or `restore.php` into the docroot. This is the safer default:
prepare helper scripts only when you know whether the site is a fresh install or
a restore.

Fresh install helper:

```bash
sudo /root/simai-env/simai-admin.sh site add \
  --domain <domain> \
  --profile bitrix \
  --php 8.2 \
  --create-db yes \
  --bitrix-files setup
```

Backup restore helper:

```bash
sudo /root/simai-env/simai-admin.sh site add \
  --domain <domain> \
  --profile bitrix \
  --php 8.2 \
  --create-db yes \
  --bitrix-files restore
```

Wildcard/subdomain site:

```bash
sudo /root/simai-env/simai-admin.sh site add \
  --domain <domain> \
  --profile bitrix \
  --host-mode wildcard \
  --php 8.2 \
  --create-db yes
```

Migration shell without DB creation:

```bash
sudo /root/simai-env/simai-admin.sh site add \
  --domain <domain> \
  --profile bitrix \
  --php 8.2 \
  --create-db no \
  --skip-db-required yes
```

## Successful Result

The site summary should show:

- `Profile: bitrix`
- selected `Host mode`
- selected PHP version
- nginx config path
- PHP-FPM pool path
- cron file path
- DB status matching your choice
- SSL status matching your choice
- next Bitrix actions

## Next Step

Choose one:

- fresh installation: [Install vs restore](install-vs-restore.md#fresh-install)
- restore from archive: [Install vs restore](install-vs-restore.md#restore-from-backup)

Before handing the site to a developer, run [Diagnostics](diagnostics.md).
