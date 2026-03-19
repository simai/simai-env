# Bitrix Production Runbook

This runbook describes the recommended Bitrix workflow on `simai-env` from fresh provisioning
to post-install hardening and daily operations.

## 1) Preconditions

- OS: Ubuntu 22.04/24.04.
- Domain points to server IP.
- TLS email is ready for Let's Encrypt.
- You have backup/restore path for project files and DB.

## 2) Phase 1: Provision a New Site

Create the site, PHP-FPM pool, DB user, managed cron file, and initial nginx config:

```bash
/root/simai-env/simai-admin.sh site add --domain <domain> --profile bitrix --php-version 8.3 --db yes --force
```

Recommended immediate checks:

```bash
/root/simai-env/simai-admin.sh site info --domain <domain>
/root/simai-env/simai-admin.sh site doctor --domain <domain>
/root/simai-env/simai-admin.sh bitrix status --domain <domain>
```

Notes:
- At this stage `dbconn.php` stays installer-safe.
- Agents-via-cron is not enabled yet.
- `site add` already prepares DB credentials and tries to download `bitrixsetup.php` best effort.

## 3) Phase 2: Prepare the Installer

If you need to regenerate installer files safely:

```bash
/root/simai-env/simai-admin.sh bitrix installer-ready --domain <domain>
```

This step ensures:
- `public/bitrix/.settings.php`
- `public/bitrix/php_interface/dbconn.php`
- `public/bitrix/php_interface/after_connect_d7.php`
- `public/bitrixsetup.php` (best effort)

Recommended verification:

```bash
/root/simai-env/simai-admin.sh bitrix status --domain <domain>
```

## 4) Phase 3: Complete Bitrix Web Installation

Open the installer in a browser:

```text
https://<domain>/bitrixsetup.php
```

Important:
- Use the DB credentials already created by `site add` / `site db-create`.
- Keep installer flow web-safe until the site finishes installation.
- Do not enable agents-via-cron before the Bitrix application/database side is ready.

## 5) Phase 4: Apply Bitrix Runtime Baseline

After Bitrix installation completes, apply the profile PHP baseline:

```bash
/root/simai-env/simai-admin.sh bitrix php-baseline-sync --domain <domain>
```

This normalizes the effective PHP-FPM runtime for Bitrix:
- `short_open_tag=on`
- `memory_limit=512M`
- `max_input_vars=10000`
- `opcache.validate_timestamps=1`
- `opcache.revalidate_freq=0`
- recommended upload/opcache values

Verify:

```bash
/root/simai-env/simai-admin.sh site doctor --domain <domain>
```

Expected outcome: no PHP runtime drift in `site doctor`.

## 6) Phase 5: Enable Agents via Cron

Check current state:

```bash
/root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
```

Plan sync:

```bash
/root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain>
```

Apply sync:

```bash
/root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain> --apply yes --confirm yes
```

Re-check:

```bash
/root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
/root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```

Expected outcome:
- `BX_CRONTAB_SUPPORT=true`
- managed cron file is present
- `Agents via cron ready = yes`

## 7) Phase 6: TLS Go-Live

Issue a production Let's Encrypt certificate:

```bash
/root/simai-env/simai-admin.sh ssl letsencrypt --domain <domain> --email <email>
/root/simai-env/simai-admin.sh ssl status --domain <domain>
```

For custom certs:

```bash
/root/simai-env/simai-admin.sh ssl install --domain <domain> --cert <fullchain.pem> --key <privkey.pem> --chain <chain.pem>
```

## 8) Phase 7: Final Acceptance Checks

CLI acceptance:

```bash
/root/simai-env/simai-admin.sh site doctor --domain <domain>
/root/simai-env/simai-admin.sh bitrix status --domain <domain>
/root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
/root/simai-env/simai-admin.sh ssl status --domain <domain>
```

Browser acceptance:

```text
https://<domain>/bitrix/admin/site_checker.php
https://<domain>/bitrix/admin/perfmon_panel.php
```

Recommended target state:
- `site doctor` is clean
- Bitrix `site_checker` has no infrastructure/runtime errors
- Bitrix `perfmon_panel` opens and shows a valid configuration score

## 9) Daily Operations

```bash
NO_COLOR=1 /root/simai-env/simai-admin.sh self status
NO_COLOR=1 /root/simai-env/simai-admin.sh self platform-status
/root/simai-env/simai-admin.sh bitrix status --domain <domain>
/root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
/root/simai-env/simai-admin.sh ssl status --domain <domain>
```

Cache maintenance when needed:

```bash
/root/simai-env/simai-admin.sh bitrix cache-clear --domain <domain>
```

## 10) Safe Change Workflow

Before risky changes (PHP switch, SSL migration, profile-level fixes):

```bash
/root/simai-env/simai-admin.sh backup export --domain <domain>
/root/simai-env/simai-admin.sh backup inspect --file <archive.tar.gz>
/root/simai-env/simai-admin.sh backup import --file <archive.tar.gz> --apply no
```

## 11) Incident Fast Path

1. `self platform-status`
2. `site doctor --domain <domain>`
3. `bitrix status --domain <domain>`
4. `bitrix agents-status --domain <domain>`
5. `ssl status --domain <domain>`
6. logs:
   - `simai-admin.sh logs admin`
   - `simai-admin.sh logs env`
   - `simai-admin.sh logs audit`

If cron/agents drift is detected, run `bitrix agents-sync` in plan mode first, then apply.
