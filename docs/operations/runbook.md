# Operator Runbook (Daily Ops)

This runbook targets day-to-day server operations for simai-env on Ubuntu 22.04/24.04.

For a compact command checklist, see `docs/operations/daily-ops-quickstart.md`.

## 1) Daily health check (read-only)

```bash
NO_COLOR=1 /root/simai-env/simai-admin.sh self status
NO_COLOR=1 /root/simai-env/simai-admin.sh self platform-status
NO_COLOR=1 /root/simai-env/simai-admin.sh site list
NO_COLOR=1 /root/simai-env/simai-admin.sh ssl list
NO_COLOR=1 /root/simai-env/simai-admin.sh db status
```

If any command fails, check logs:

```bash
/root/simai-env/simai-admin.sh logs admin
/root/simai-env/simai-admin.sh logs env
/root/simai-env/simai-admin.sh logs audit
```

## 2) Site-level diagnosis

```bash
/root/simai-env/simai-admin.sh site info --domain <domain>
/root/simai-env/simai-admin.sh site doctor --domain <domain>
/root/simai-env/simai-admin.sh site drift --domain <domain>
/root/simai-env/simai-admin.sh ssl status --domain <domain>
```

## 3) SSL operations

Issue Let's Encrypt:

```bash
/root/simai-env/simai-admin.sh ssl letsencrypt --domain <domain> --email <email>
```

Install manual certificate:

```bash
/root/simai-env/simai-admin.sh ssl install --domain <domain> --cert <fullchain.pem> --key <privkey.pem> --chain <chain.pem>
```

Remove SSL:

```bash
/root/simai-env/simai-admin.sh ssl remove --domain <domain>
```

## 4) Config backup and restore

Export:

```bash
/root/simai-env/simai-admin.sh backup export --domain <domain>
```

Inspect:

```bash
/root/simai-env/simai-admin.sh backup inspect --file <archive.tar.gz>
```

Import plan (dry-run):

```bash
/root/simai-env/simai-admin.sh backup import --file <archive.tar.gz> --apply no
```

Import apply:

```bash
/root/simai-env/simai-admin.sh backup import --file <archive.tar.gz> --apply yes
```

## 5) Regression gates

Use before release or after major host changes:

```bash
bash /root/simai-env/testing/run-regression.sh smoke
bash /root/simai-env/testing/run-regression.sh full
```

## 6) Incident quick path

1. Run `self platform-status` and `db status`.
2. Run `site doctor --domain <domain>` and `ssl status --domain <domain>`.
3. Check admin/env/audit logs.
4. If config drift detected, use `site drift --domain <domain>` first, and only then apply fixes.

## 7) Safety notes

- Use disposable domains for destructive testing (`*.env.sf8.ru`, `*.sf0.ru`).
- Do not store private keys or DB passwords in git.
- Avoid mutating non-test domains unless explicitly approved.
