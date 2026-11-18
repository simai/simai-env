---
title: Logs
description: Logs
---

# logs commands

Run with `sudo /root/simai-env/simai-admin.sh logs <command> [options]` or via menu.

These commands provide quick access to the most useful platform logs without remembering full file paths.

Default tail length: `200` lines. Override with `--lines <n>`.

## admin
Tail the main admin log.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh logs admin
sudo /root/simai-env/simai-admin.sh logs admin --lines 500
```

File:
- `/var/log/simai-admin.log`

## env
Tail the environment/bootstrap log.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh logs env
```

File:
- `/var/log/simai-env.log`

## audit
Tail the audit log.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh logs audit
```

File:
- `/var/log/simai-audit.log`

This log records command start/finish with correlation IDs and redacted arguments.

## nginx
Tail one site's nginx access or error log.

Options:
- `--domain <domain>` (required outside menu)
- `--kind access|error` (default `access`)
- `--lines <n>`
- `--match <text>` (JSON output): the last lines containing it
- `--status 4xx,5xx` (JSON output, access log, 1.60.0): the last lines with
  these statuses (`4xx`, `5xx`, or a code such as `404`)
- `--format json` (JSON output, 1.60.0): adds `entries` with `at` (ISO 8601
  with the zone), `level`, `status`, `method`, `path`, `ip`, `message`, `raw`

With `--output json` `--lines` goes up to 10000.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh logs nginx --domain example.com --kind access
sudo /root/simai-env/simai-admin.sh logs nginx --domain example.com --kind error --lines 300
```

Menu mapping:
- `Logs -> Website access log`
- `Logs -> Website error log`

## letsencrypt
Tail the Let's Encrypt / certificate log.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh logs letsencrypt
```

File:
- `/var/log/letsencrypt/letsencrypt.log`
