# Bitrix Production Runbook

This runbook describes a practical production workflow for Bitrix sites on `simai-env`.

## 1) Preconditions

- OS: Ubuntu 22.04/24.04.
- Domain points to server IP.
- TLS email is ready for Let's Encrypt.
- You have backup/restore path for project files and DB.

## 2) Initial Provisioning (new Bitrix site)

```bash
/root/simai-env/simai-admin.sh site add --domain <domain> --profile bitrix --php-version 8.3 --db yes --force
```

Verify baseline:

```bash
/root/simai-env/simai-admin.sh site info --domain <domain>
/root/simai-env/simai-admin.sh site doctor --domain <domain>
/root/simai-env/simai-admin.sh bitrix status --domain <domain>
```

At this stage `dbconn.php` stays installer-safe: agents-via-cron is not enabled yet.
Switch agents to cron only after the application/database side is ready.

## 3) Agents via Cron Baseline

Check current state:

```bash
/root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
```

Plan sync:

```bash
/root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain>
```

Apply sync (CLI requires confirm):

```bash
/root/simai-env/simai-admin.sh bitrix agents-sync --domain <domain> --apply yes --confirm yes
```

Re-check:

```bash
/root/simai-env/simai-admin.sh bitrix agents-status --domain <domain>
/root/simai-env/simai-admin.sh bitrix cron-status --domain <domain>
```

## 4) TLS Go-Live

```bash
/root/simai-env/simai-admin.sh ssl letsencrypt --domain <domain> --email <email>
/root/simai-env/simai-admin.sh ssl status --domain <domain>
```

For custom certs:

```bash
/root/simai-env/simai-admin.sh ssl install --domain <domain> --cert <fullchain.pem> --key <privkey.pem> --chain <chain.pem>
```

## 5) Recommended Runtime Baseline

- PHP: use 8.3 by default; 8.4 can be validated project-by-project.
- Profile allows `8.2/8.3/8.4`.
- Apply profile PHP baseline carefully:

```bash
/root/simai-env/simai-admin.sh site fix --domain <domain> --apply all --include-recommended yes --confirm yes
```

Then verify:

```bash
/root/simai-env/simai-admin.sh site doctor --domain <domain>
```

## 6) Daily Operations

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

## 7) Safe Change Workflow

Before risky changes (PHP switch, SSL migration, profile-level fixes):

```bash
/root/simai-env/simai-admin.sh backup export --domain <domain>
/root/simai-env/simai-admin.sh backup inspect --file <archive.tar.gz>
/root/simai-env/simai-admin.sh backup import --file <archive.tar.gz> --apply no
```

## 8) Incident Fast Path

1. `self platform-status`
2. `site doctor --domain <domain>`
3. `bitrix status --domain <domain>`
4. `bitrix agents-status --domain <domain>`
5. `ssl status --domain <domain>`
6. logs:
   - `simai-admin.sh logs admin`
   - `simai-admin.sh logs env`
   - `simai-admin.sh logs audit`

If cron/agents drift is detected: run `bitrix agents-sync` in plan mode first, then apply.
