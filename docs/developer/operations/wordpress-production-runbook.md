# WordPress Production Runbook

This runbook describes a practical production workflow for WordPress sites on `simai-env`.

## 1) Preconditions

- OS: Ubuntu 22.04/24.04.
- Domain points to server IP.
- TLS email is ready for Let's Encrypt.
- You have backup/restore path for project files and DB.

## 2) Initial Provisioning (new WordPress site)

```bash
/root/simai-env/simai-admin.sh site add --domain <domain> --profile wordpress --php 8.3 --db yes --force
/root/simai-env/simai-admin.sh wp installer-ready --domain <domain>
```

Then open:

```bash
http://<domain>/wp-admin/install.php
```

Complete the web installer, then finalize:

```bash
/root/simai-env/simai-admin.sh wp finalize --domain <domain> --confirm yes
```

Verify baseline:

```bash
/root/simai-env/simai-admin.sh site info --domain <domain>
/root/simai-env/simai-admin.sh site doctor --domain <domain>
/root/simai-env/simai-admin.sh wp status --domain <domain>
```

## 3) Scheduler Baseline

Check current state:

```bash
/root/simai-env/simai-admin.sh wp cron-status --domain <domain>
```

Sync managed cron:

```bash
/root/simai-env/simai-admin.sh wp cron-sync --domain <domain>
```

Re-check:

```bash
/root/simai-env/simai-admin.sh wp cron-status --domain <domain>
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

- PHP: use 8.3 by default; evaluate 8.4 project-by-project.
- Apply WordPress optimization baseline if not already done via `wp finalize`:

```bash
/root/simai-env/simai-admin.sh wp perf-apply --domain <domain> --mode standard --confirm yes
```

Then verify:

```bash
/root/simai-env/simai-admin.sh site doctor --domain <domain>
```

## 6) Daily Operations

```bash
NO_COLOR=1 /root/simai-env/simai-admin.sh self status
NO_COLOR=1 /root/simai-env/simai-admin.sh self platform-status
/root/simai-env/simai-admin.sh wp status --domain <domain>
/root/simai-env/simai-admin.sh wp cron-status --domain <domain>
/root/simai-env/simai-admin.sh wp perf-status --domain <domain>
/root/simai-env/simai-admin.sh ssl status --domain <domain>
```

Cache maintenance when needed:

```bash
/root/simai-env/simai-admin.sh wp cache-clear --domain <domain>
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
3. `wp status --domain <domain>`
4. `wp cron-status --domain <domain>`
5. `wp perf-status --domain <domain>`
6. `ssl status --domain <domain>`
7. logs:
   - `simai-admin.sh logs admin`
   - `simai-admin.sh logs env`
   - `simai-admin.sh logs audit`

If cron drift is detected: run `wp cron-sync` and re-check `wp cron-status`.
