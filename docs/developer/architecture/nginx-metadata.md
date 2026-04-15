# Nginx Metadata

Use this document when you need the canonical metadata contract embedded in generated nginx configs.

Why it matters:

- these headers are the source of truth for many admin operations,
- safe updates and drift detection depend on their presence,
- tooling should read and preserve them consistently.

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

Related docs:

- [architecture/site-metadata.md](./site-metadata.md)
- [commands/site.md](../commands/site.md)
- [commands/ssl.md](../commands/ssl.md)
