# Idempotency

- Install/bootstrap steps check for existing repos, packages, and services; reruns avoid breaking state.
- Site creation reuses existing paths and metadata when possible and backs up nginx configs before rewriting.
- SSL apply is transactional: backs up nginx config, restores on failure.
- set-php patches nginx upstream in-place; re-tests config and reloads safely.
- Destructive actions (files/DB/user) require explicit confirmation; static/alias profiles skip DB removal entirely.
