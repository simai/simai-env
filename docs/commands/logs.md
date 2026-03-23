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
