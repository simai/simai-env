# Profile commands

Manage profile activation and lint profiles.

## validate
`simai-admin.sh profile validate [--id <id>] [--all yes]`  
Lint profile files (read-only). Exits 1 on FAIL findings.

## list
`simai-admin.sh profile list [--all yes]`  
Shows profiles and status. By default lists only enabled profiles; `--all yes` shows disabled too. Reports activation mode (legacy vs allowlist at `/etc/simai-env/profiles.enabled`).

## used-by
`simai-admin.sh profile used-by [--id <id>]`  
Lists sites using profiles. With `--id`, prints domains using that profile.

## enable
`simai-admin.sh profile enable --id <id>`  
Adds a profile to the allowlist (creates allowlist if missing).

## disable
`simai-admin.sh profile disable --id <id> [--force yes]`  
Removes a profile from the allowlist. Core profiles (static, generic, alias) or profiles in use cannot be disabled without `--force yes`.

## init
`simai-admin.sh profile init [--mode core|all] [--force yes]`  
Creates `/etc/simai-env/profiles.enabled`. Default `mode=core` keeps core (`static`, `generic`, `alias`) + profiles used by existing sites. `mode=all` seeds all profiles. Use `--force yes` to overwrite an existing allowlist.
Install/repair calls `profile init --mode core` on fresh systems (no sites/allowlist).

## Notes
- If `/etc/simai-env/profiles.enabled` is missing, activation runs in legacy mode (all profiles enabled). Managing profiles creates the allowlist.
- `site add` only lists enabled profiles; enable a profile first if you want it selectable.
