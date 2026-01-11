# Nginx site metadata (simai)

Simai-managed nginx site configs carry a canonical metadata header that acts as the single source of truth for admin operations (list/remove/doctor/set-php/ssl). The block must be placed at the top of each site config and uses simple `# simai-*` markers.

Required keys (metadata v2):
- `# simai-managed: yes`
- `# simai-meta-version: 2`
- `# simai-domain: <domain>`
- `# simai-slug: <safe_slug>`
- `# simai-profile: <profile_id>`
- `# simai-root: </home/simai/www/<domain>>`
- `# simai-project: <safe_project_name>`
- `# simai-php: <8.1|8.2|8.3|none>`
- `# simai-ssl: <none|letsencrypt|custom|unknown>`
- `# simai-public-dir: <relative docroot or empty/"." for project root>`
- `# simai-updated-at: <YYYY-MM-DD>`

Notes:
- Keep the block together near the file start, followed by a blank line before server{} content.
- All site creation/updates must write or update this block; admin tooling parses it to avoid drift.
- Future versions may extend keys; metadata version is explicit to allow migration.
