# backup commands

Run with `sudo /root/simai-env/simai-admin.sh backup <command> [options]` or via menu under **Backup / Migrate**.

## export
Create a config-only bundle for migration (no databases, project files, or certificates).

Options:
- `--output <path>` (default `/root/simai-backup-<timestamp>.tar.gz`)
- `--include-nginx yes|no` (default `no`; copies nginx vhost configs as reference)
- `--domains <d1,d2>` (optional filter; defaults to all sites with simai metadata)
- `--dry-run yes|no` (default `no`; show what would be exported without writing the archive)

Contents:
- `manifest.json` (schema_version=1) with host info and site metadata (domain, profile, root, php, ssl type/state) derived from simai nginx metadata.
- `summary.txt` table.
- Optional copies of `/etc/nginx/sites-available/<domain>.conf` when `--include-nginx yes`.

Security:
- No DB credentials, `.env`, project files, certificates, or private keys are included.
- SSL presence/type is noted via metadata/paths only.

Example:
`simai-admin.sh backup export --include-nginx yes`

## inspect
Inspect a backup bundle (read-only, plan-only).

Options:
- `--input <path>` (required)

Behavior:
- Extracts into a temp dir, reads `manifest.json`, and prints manifest fields (schema_version, generated_at, simai version, host info).
- Prints `summary.txt` if present.
- Warns when: required profiles are disabled, referenced PHP versions are not installed, or alias targets are missing locally/within the backup.
- Notes SSL presence from manifest metadata (certificates/keys are not included; configure SSL manually after import when reported).
- No changes are made.

Example:
`simai-admin.sh backup inspect --input /root/simai-backup-20260101.tar.gz`

## import
Plan or apply a backup bundle. Safe by default (plan-only); apply is explicit.

Options:
- `--input <path>` (required)
- `--apply yes|no` (default `no`; plan-only)
- `--domains d1,d2` (optional filter)

Behavior and safety:
- Never touches databases, secrets, or certificates; does not install packages.
- Never overwrites existing sites: existing domains are marked SKIP.
- Alias targets must already exist locally (or be part of the same import); otherwise BLOCK.
- Profiles that are disabled are auto-enabled during apply (idempotent).
- Required-DB profiles are created without DB by design (note is shown); create DB later via `site db-create`. Optional-DB profiles are noted separately.
- Profiles requiring PHP block when the backup manifest lacks a PHP version or when the required version is not installed (non-interactive safety).
- SSL presence in metadata is surfaced in plan notes as a reminder to configure certs manually after import.
- Plan prints a table (Domain/Profile/PHP/Path/Target/Action/Notes) with counts ADD/SKIP/BLOCK.
- Apply (`--apply yes`) runs without prompts, processes non-alias first, then alias, respecting the above constraints.

Example (plan):
`simai-admin.sh backup import --input /root/simai-backup-20260101.tar.gz`

Example (apply):
`simai-admin.sh backup import --input /root/simai-backup-20260101.tar.gz --apply yes`
