# Security Model

- OS scope: Ubuntu 22.04/24.04 only.
- Web root: always `<project-root>/public`; catch-all default_server returns 444.
- Least privilege:
  - shared account `simai` owns `/home/simai` and runs legacy sites
  - per-site Unix users: every new site gets `site-<slug>` (group of the same
    name, no shell, home under `/var/lib/simai-env/site-homes/`). Its PHP-FPM
    pool, cron lines and queue worker run as that user; project files are
    `site-<slug>:site-<slug>` with the project root `0750`, and nginx reads
    them because `www-data` is a member of each site group. A compromised
    site cannot read or modify another site. The mapping lives in
    `/etc/simai-env/site-users/<slug>`.
  - owners (`owner create`) group several sites under one account with SSH
    access for deploys; isolation is then between owners. Owner SSH keys live
    in root-owned `/etc/ssh/simai-owner-keys/`.
  - sites created before this change keep running as `simai` until
    `site isolate --domain <domain> --confirm yes` moves them; while any
    legacy site remains, a compromise of one legacy site still exposes the
    other legacy sites (not isolated ones).
  - `SIMAI_SITE_ISOLATION=no` in `/etc/simai-env.conf` restores the old
    shared-user behaviour for new sites.
  - per-site PHP-FPM pools (static/alias skip pools); opcache uses
    `validate_permission`/`validate_root` when isolated pools exist
  - optional non-root sudo operator account managed by `self sudo-admin-ensure`
- Administration modes:
  - simple mode: trusted owner/admin uses `root` through SSH keys only; password login is disabled
  - hardened mode: `simai-admin` is the daily sudo operator and `root` remains key-only break-glass access
- SSH hardening default: operational-safe mode. Password and keyboard-interactive SSH login are disabled, public-key login remains enabled, and root remains available as key-only break-glass access (`PermitRootLogin prohibit-password`) unless an operator explicitly chooses a stricter local policy.
- The `simai` and `site-*` accounts are runtime-only and must not receive sudo; site PHP-FPM and cron run under them, so granting sudo would couple web compromise with server compromise.
- Runtime hardening should not block normal site operations: missing Redis PHP extension is a recommendation/warning unless a specific application requires it.
- Secrets never logged: passwords are shown only in summaries and redacted in logs/audit.
- SSL:
  - TLS configs regenerated from templates; certs stored under `/etc/letsencrypt/live/<domain>/` or `/etc/nginx/ssl/<domain>/`.
  - Healthcheck endpoints are local-only by default.
- Input validation: domains/paths are sanitized; reserved RFC 2606 domains blocked unless explicitly allowed.
- Idempotency: operations validate state and apply safe defaults; destructive actions gated by confirmations.
