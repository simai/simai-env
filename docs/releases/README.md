# Releases

- [v1.43.2](v1.43.2.md) — faster software, PHP and update plan reads.
- [v1.43.0](v1.43.0.md) — server programs as a catalogue with install,
  update and remove.
- [v1.42.1](v1.42.1.md) — update plan codes for the panel; the panel
  build's own version.
- [v1.42.0](v1.42.0.md) — Apache mode for PHP sites that rely on
  `.htaccess`.
- [v1.41.0](v1.41.0.md) — a site's own nginx directives, undone unless
  confirmed.
- [v1.40.0](v1.40.0.md) — file uploads, archives and extraction in the file
  manager.
- [v1.39.0](v1.39.0.md) — the file manager: browse, edit, rename, remove and
  download site files as the site user.
- [v1.38.0](v1.38.0.md) — server software and system updates with a site
  check; Node.js, Redis and PostgreSQL installs.
- [v1.37.0](v1.37.0.md) — PHP versions as software: install, remove,
  extensions and updates, from the CLI and the panel.
- [v1.36.0](v1.36.0.md) — certificates through Cloudflare DNS, before the
  domain points at the server.
- [v1.35.0](v1.35.0.md) — firewall rules, address blocks and panel access by
  address, each undone unless confirmed.
- [v1.34.0](v1.34.0.md) — site cron jobs with run records, from the CLI and
  the panel.
- [v1.33.0](v1.33.0.md) — host services, site profiles for the wizard, a
  reverse proxy profile, Bitrix sites from the panel, Larena Panel 0.3.0.
- [v1.32.0](v1.32.0.md) — safe update of simai-env and the panel from the
  panel: a plan first, site checks after, rollback.
- [v1.31.0](v1.31.0.md) — server alerts to a webhook or Telegram, and the
  load history, kept by the server itself.
- [v1.30.0](v1.30.0.md) — SFTP accounts by key in the panel gateway, a
  check after each scheduled backup, a daily backup for new sites,
  certificate renewal results.
- [v1.29.0](v1.29.0.md) — a static site switches to profile node in place
  (`site set-profile`), keeping its releases.
- [v1.28.0](v1.28.0.md) — backups, PHP settings, server metrics and
  databases in the panel gateway.
- [v1.27.0](v1.27.0.md) — site answers, disk and last backup in the host
  description; blocking owners.
- [v1.26.1](v1.26.1.md) — the panel installs on a new server; the installer
  works on Ubuntu 26.04 by default.
- [v1.26.0](v1.26.0.md) — `panel install` and `panel update` use the published
  Larena Panel; `install.sh --with-panel`.
- [v1.25.0](v1.25.0.md) — Larena Panel: the build installed through adopt
  with a health check, and `panel update`.
- [v1.24.0](v1.24.0.md) — fonts on static sites load from other origins
  and sandboxed frames.
- [v1.23.1](v1.23.1.md) — `install.sh` installs the panel with the server.
- [v1.23.0](v1.23.0.md) — `panel install`: SIMAI ENV Panel as its own site,
  placeholder until the Larena build.
- [v1.22.0](v1.22.0.md) — panel deploys, creating and removing sites,
  databases, redirects and owners.
- [v1.21.0](v1.21.0.md) — panel actions as jobs; certificates, backups and
  logs as data.
- [v1.20.0](v1.20.0.md) — read-only panel gateway for SIMAI ENV Panel.
- [v1.19.0](v1.19.0.md) — whole-domain redirects to the target's root page
  (`--redirect-path drop`).
- [v1.18.2](v1.18.2.md) — charset utf-8 on node sites with a static root.
- [v1.18.1](v1.18.1.md) — deny rules cover prefix locations.
- [v1.18.0](v1.18.0.md) — node sites with a static root and service routes,
  per-path headers and cache rules, `site paths-allow`.
- [v1.17.4](v1.17.4.md) — SIMAI_STATE_DIR for node services.
- [v1.17.3](v1.17.3.md) — static sites send charset utf-8.
- [v1.17.2](v1.17.2.md) — path redirects keep the query string.
- [v1.17.1](v1.17.1.md) — releases readable by nginx on shared-account hosts.
- [v1.17.0](v1.17.0.md) — static deploys from CI artifacts, per-site deploy
  keys, redirects, GitHub Pages behaviour for static sites.
- [v1.16.3](v1.16.3.md) — HTTP/2 on HTTPS sites, `X-Content-Type-Options:
  nosniff` on every template.
- [v1.16.2](v1.16.2.md) — certificate renewals always reload nginx.
- [v1.16.1](v1.16.1.md) — TLS on node sites, no duplicated intermediates.
- [v1.16.0](v1.16.0.md) — Ubuntu 26.04, profile node for long-running
  services, swap/firewall/settings commands, detailed plans.
- [v1.15.0](v1.15.0.md) — confirmation before changes, fail-fast handlers,
  locks, JSON results, Bitrix request budget and MySQL localization.
- [v1.14.0](v1.14.0.md) — PostgreSQL sites, application manifest, site adopt
  and release deploys, frame ancestors, AI-first describe.
- [v1.13.0](v1.13.0.md) — per-site users and owners, data backups, root
  escalation fixes, Bitrix short_open_tag fix and host migrations.
- [v1.12.78](v1.12.78.md) — fail-closed integrity validation for every Bitrix
  restore archive volume.
- [v1.12.77](v1.12.77.md) — reliable Bitrix archive restore preparation on
  PHP 8 and clearer site-creation cancellation diagnostics.
- [v1.12.76](v1.12.76.md) — forward CI correction for the registry dispatch
  harness.
- [v1.12.75](v1.12.75.md) — menu safety, transactional site creation,
  adaptive terminal UX and complete command coverage.
