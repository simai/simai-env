# Profiles Development

- Profiles live in `profiles/<id>.profile.sh` and contain only `PROFILE_` variables (no commands or control structures).
- Keep public web root as `public` for all profiles.
- Validate files with `validate_profile_file` and load via `load_profile`.
- Adding a profile must not require changes to existing commands; menu/profile selection reads the registry dynamically.
- Update `docs/architecture/profiles.md` and `docs/architecture/profiles-spec.md` when adding/changing profile fields.
- Before committing, run `simai-admin.sh profile validate` (or `--id <id>`) to lint profiles.

## Profile file restrictions
- Profiles are sourced as data: no variable expansion or command substitution is allowed.
- Forbidden substrings: `$`, `$(`, backticks, `<(`, `>(`, `|`, `;`, `&`, `>`, `<`.
- Allowed lines: empty, comments, or `PROFILE_*=` assignments (arrays/scalars).
