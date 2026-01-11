# Nginx Metadata

simai-env embeds site metadata in nginx configs as `# simai-*` comments. These are the source of truth for admin commands.

Common fields:
- `# simai-meta-version: 2`
- `# simai-domain: <domain>`
- `# simai-profile: <profile>`
- `# simai-project: <project-slug>`
- `# simai-root: <project-root>`
- `# simai-php: <php-version>` (or `none` for static/alias)
- `# simai-target: <alias-target-domain>` (alias only)
- `# simai-php-socket-project: <socket-project>`
- `# simai-ssl: on|off`
- `# simai-public-dir: <relative docroot or empty/"." for project root>`

Rules:
- Always present in generated configs.
- Admin commands read these headers to determine profile/root/php/socket for updates (SSL, set-php, remove).
- Do not edit manually unless you know the implications; use admin commands to keep metadata consistent.
