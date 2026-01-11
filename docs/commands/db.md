# Database commands (per-site)

Manage MySQL databases and users for individual sites. Credentials are stored at `/etc/simai-env/sites/<domain>/db.env` (mode 0640, root owned); passwords are never logged.

## db-status
`simai-admin.sh site db-status --domain <domain>`
- Shows db.env presence, DB name/user/host/charset/collation (without password), and existence of DB/user/grants.

## db-create
`simai-admin.sh site db-create --domain <domain> [--dry_run yes] [--confirm yes]`
- Profile-aware defaults for charset/collation/privileges; refuses when profile declares no DB.
- Dry-run prints the plan only. Real execution requires `--confirm yes` in CLI (menu asks interactively).
- Creates DB + user and grants privileges, then writes db.env (DB_PASS shown once to stdout, not logged).

## db-drop
`simai-admin.sh site db-drop --domain <domain> [--dry_run yes] [--confirm yes] [--remove_files yes]`
- Dry-run prints what would be dropped. Real execution requires confirmation.
- Drops DB and user; removes db.env only when `--remove_files yes`.

## db-rotate
`simai-admin.sh site db-rotate --domain <domain> [--dry_run yes] [--confirm yes]`
- Rotates the DB user password, updates db.env, and prints the new password once.

## db-export
`simai-admin.sh site db-export --domain <domain> [--target .env] [--confirm yes]`
- Writes DB_HOST/DB_DATABASE/DB_USERNAME/DB_PASSWORD into the target file under the project directory (default `.env`), idempotently updating keys.
- Requires confirmation in CLI; menu asks interactively. Password is not logged.

Notes:
- Commands use MySQL root via socket auth; no passwords are logged.
- CLI requires explicit confirmation for destructive/creating actions; menu always asks.
- db.env under `/etc/simai-env/sites/<domain>/` is the source of truth; export to project envs is a separate, idempotent step.

## Legacy db commands
Legacy commands (`db create/drop/set-pass`) remain for backward compatibility but are deprecated. Prefer the site-scoped commands (`site db-create/db-drop/db-rotate/db-export`) which handle profile defaults, safe storage, and better confirmations.
