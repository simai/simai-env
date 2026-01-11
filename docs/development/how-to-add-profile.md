# How to add a profile

Profiles are declarative files under `profiles/<id>.profile.sh` and are consumed by simai-admin to drive site lifecycle. See `docs/architecture/profiles.md` and `docs/architecture/profiles-spec.md` for background and field definitions.

## File location and skeleton
Create `profiles/<id>.profile.sh` with only `PROFILE_` variables (no commands/functions). Start from this template:
```
PROFILE_ID="<id>"
PROFILE_TITLE="My Profile"
PROFILE_PUBLIC_DIR="public"
PROFILE_NGINX_TEMPLATE="nginx-myprofile.conf"
PROFILE_REQUIRES_PHP="yes"
PROFILE_REQUIRES_DB="optional"
PROFILE_HEALTHCHECK_ENABLED="yes"
PROFILE_HEALTHCHECK_MODE="php"
PROFILE_REQUIRED_MARKERS=()
PROFILE_BOOTSTRAP_FILES=()
PROFILE_WRITABLE_PATHS=()
PROFILE_ALLOWED_PHP_VERSIONS=()
PROFILE_PHP_EXTENSIONS_REQUIRED=()
PROFILE_PHP_EXTENSIONS_RECOMMENDED=()
PROFILE_PHP_INI_REQUIRED=()
PROFILE_PHP_INI_RECOMMENDED=()
PROFILE_PHP_INI_FORBIDDEN=()
PROFILE_SUPPORTS_CRON="no"
PROFILE_CRON_RECOMMENDED=()
PROFILE_SUPPORTS_QUEUE="no"
PROFILE_IS_ALIAS="no"
PROFILE_ALLOW_PHP_SWITCH="yes"
```

## Required fields
- `PROFILE_ID`, `PROFILE_TITLE`
- `PROFILE_PUBLIC_DIR` (always `public`)
- `PROFILE_NGINX_TEMPLATE` (filename only, lives under `templates/`, no slashes/spaces; may be empty for alias profiles)
- `PROFILE_REQUIRES_PHP` (`yes|no`)
- `PROFILE_REQUIRES_DB` (`no|optional|required`)

## Common optional fields
- Filesystem: `PROFILE_REQUIRED_MARKERS`, `PROFILE_BOOTSTRAP_FILES`, `PROFILE_WRITABLE_PATHS`
- Healthcheck: `PROFILE_HEALTHCHECK_ENABLED`, `PROFILE_HEALTHCHECK_MODE (php|nginx)`
- PHP: `PROFILE_ALLOWED_PHP_VERSIONS`, `PROFILE_PHP_EXTENSIONS_REQUIRED/RECOMMENDED`, `PROFILE_PHP_INI_REQUIRED/RECOMMENDED/FORBIDDEN`
- Cron/queue: `PROFILE_SUPPORTS_CRON`, `PROFILE_CRON_RECOMMENDED`, `PROFILE_SUPPORTS_QUEUE`
- Alias rules: `PROFILE_IS_ALIAS`, `PROFILE_ALLOW_PHP_SWITCH`

## Safety rules
- No functions, control structures, sourcing, command substitution, or shell commands.
- Only declare `PROFILE_` variables (scalars or arrays); keep web root `public`.
- Nginx template filenames must not contain `/`, `..`, or spaces and must exist under `templates/` (aliases may leave it empty).

## Test checklist
- `simai-admin.sh site add --domain <domain> --profile <id> --path <path> --php <ver>`
- `simai-admin.sh site doctor --domain <domain>`
- `simai-admin.sh site fix --domain <domain> --apply none` (plan) or apply as needed
- `simai-admin.sh site remove --domain <domain> --dry-run yes`
- `nginx -t`
- Repeat for alias/static interactions if applicable.

## Validate before commit
- Run `simai-admin.sh profile validate` to lint all profiles.
- For a single profile: `simai-admin.sh profile validate --id <id>`
