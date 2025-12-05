# logs commands

`logs` commands help inspect recent output from installer/admin/audit and nginx/Let’s Encrypt logs. Default tail length: 200 lines (override with `--lines`).

## logs admin
- Tails `/var/log/simai-admin.log`.
- Options: `--lines` (default 200).

## logs env
- Tails installer log `/var/log/simai-env.log`.
- Options: `--lines` (default 200).

## logs audit
- Tails audit log `/var/log/simai-audit.log` (command start/finish with correlation IDs).
- Options: `--lines` (default 200).

## logs nginx
- Select a domain from existing sites (aliases allowed, catch-all hidden) and tail nginx access/error log.
- Options:
  - `--domain` domain name (optional when using menu).
  - `--kind` `access` (default) or `error`.
  - `--lines` tail length (default 200).

## logs letsencrypt
- Tails `/var/log/letsencrypt/letsencrypt.log`.
- Options: `--lines` (default 200).
