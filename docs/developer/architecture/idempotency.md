# Idempotency

Use this document when you need the high-level safety promises behind repeated installer or admin runs.

Why it matters:

- much of `simai-env` is expected to be rerunnable,
- rollback and confirm semantics depend on these guarantees,
- developer changes should preserve these behaviors.

- Install/bootstrap steps check for existing repos, packages, and services; reruns avoid breaking state.
- Site creation reuses existing paths and metadata when possible and backs up nginx configs before rewriting.
- SSL apply is transactional: backs up nginx config, restores on failure.
- set-php patches nginx upstream in-place; re-tests config and reloads safely.
- Destructive actions (files/DB/user) require explicit confirmation; static/alias profiles skip DB removal entirely.

Related docs:

- [architecture/security-model.md](./security-model.md)
- [commands/site.md](../commands/site.md)
- [commands/ssl.md](../commands/ssl.md)
