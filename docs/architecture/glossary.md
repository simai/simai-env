# Glossary

- `<domain>`: the site’s DNS name, used for nginx config names and default project root.
- `<project-root>`: `/home/simai/www/<domain>` (default filesystem location for a site).
- `<project-slug>`: a normalized identifier derived from the domain (e.g., `env-sf8-ru`), used for PHP-FPM pool names, cron files (`/etc/cron.d/<project-slug>`), queue units, sockets, and log names.
- Web root: always `<project-root>/public` for all profiles.
- Nginx config: `/etc/nginx/sites-available/<domain>.conf` with a symlink in `sites-enabled`.
