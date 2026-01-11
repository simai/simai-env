# Security Model

- OS scope: Ubuntu 22.04/24.04 only.
- Web root: always `<project-root>/public`; catch-all default_server returns 444.
- Least privilege:
  - dedicated user `simai`
  - per-site PHP-FPM pools (static/alias skip pools)
  - sockets/logs owned by `simai`:www-data
- Secrets never logged: passwords are shown only in summaries and redacted in logs/audit.
- SSL:
  - TLS configs regenerated from templates; certs stored under `/etc/letsencrypt/live/<domain>/` or `/etc/nginx/ssl/<domain>/`.
  - Healthcheck endpoints are local-only by default.
- Input validation: domains/paths are sanitized; reserved RFC 2606 domains blocked unless explicitly allowed.
- Idempotency: operations validate state and apply safe defaults; destructive actions gated by confirmations.
