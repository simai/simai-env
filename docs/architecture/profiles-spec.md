# Profiles Specification

Profiles are declarative bash-compatible data files describing requirements and constraints for a site. Files live in `profiles/<id>.profile.sh` and contain only `PROFILE_` variable declarations (no commands or control structures).

## Required fields
- `PROFILE_ID`, `PROFILE_TITLE`
- `PROFILE_PUBLIC_DIR` (web root, relative path or empty/"." for project root; default `public` when unset)
- `PROFILE_REQUIRES_PHP` (`yes|no`)
- `PROFILE_REQUIRES_DB` (`no|optional|required`)
- `PROFILE_NGINX_TEMPLATE` (filename under `templates/`; may be empty for alias profiles)

## Recommended fields (v1)
- Filesystem/bootstrap: `PROFILE_BOOTSTRAP_FILES`, `PROFILE_WRITABLE_PATHS`, `PROFILE_HEALTHCHECK_ENABLED`, `PROFILE_REQUIRED_MARKERS`
- Healthcheck: `PROFILE_HEALTHCHECK_MODE` (`php` or `nginx`) when enabled
- PHP runtime: `PROFILE_ALLOWED_PHP_VERSIONS`, `PROFILE_PHP_EXTENSIONS_REQUIRED/RECOMMENDED/OPTIONAL`, `PROFILE_PHP_INI_REQUIRED/RECOMMENDED/FORBIDDEN`
- Database: `PROFILE_DB_ENGINE`, `PROFILE_DB_CHARSET`, `PROFILE_DB_COLLATION`, `PROFILE_DB_REQUIRED_PRIVILEGES`
- Background: `PROFILE_SUPPORTS_CRON`, `PROFILE_CRON_RECOMMENDED`, `PROFILE_SUPPORTS_QUEUE`, `PROFILE_QUEUE_SYSTEM`
- Security: `PROFILE_ALLOW_ALIAS`, `PROFILE_ALLOW_PHP_SWITCH`, `PROFILE_ALLOW_SHARED_POOL`, `PROFILE_ALLOW_DB_REMOVAL`
- Hooks (placeholders): `PROFILE_HOOKS_PRE_CREATE/POST_CREATE/PRE_REMOVE/POST_REMOVE`

## Rules
- No executable logic in profile files.
- Public directory is profile-driven; must be a safe relative path (no `/`, `..`, trailing `/`, whitespace, or backslashes). Empty or `.` means project root.
- Profiles are backward-compatible within a major version; adding a profile does not require changing existing code.

## Doctor checks
The read-only `site doctor` uses these profile fields when validating a site (no fixes are applied):
- `PROFILE_REQUIRED_MARKERS`, `PROFILE_BOOTSTRAP_FILES`, `PROFILE_WRITABLE_PATHS`
- `PROFILE_HEALTHCHECK_ENABLED`, `PROFILE_HEALTHCHECK_MODE`
- `PROFILE_SUPPORTS_CRON`
- `PROFILE_PHP_EXTENSIONS_REQUIRED/RECOMMENDED`
- `PROFILE_PHP_INI_REQUIRED/RECOMMENDED/FORBIDDEN`
- `PROFILE_REQUIRES_PHP`, `PROFILE_REQUIRES_DB`

## Fixer
The `site fix` command (plan-by-default) uses these profile fields to install/update PHP runtime configuration:
- Extensions: `PROFILE_PHP_EXTENSIONS_REQUIRED` (always), `PROFILE_PHP_EXTENSIONS_RECOMMENDED` (when requested)
- INI overrides: `PROFILE_PHP_INI_REQUIRED` (always), `PROFILE_PHP_INI_RECOMMENDED` (when requested)
- Forbidden INI are only reported by doctor (not auto-fixed).
