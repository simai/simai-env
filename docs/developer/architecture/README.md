# Architecture

Use this section when you need the internal model of how `simai-env` works.

This is the right place for:

- source-of-truth architecture,
- metadata layout and filesystem rules,
- profile model and constraints,
- versioning and security model,
- internal format documents.

Recommended reading order:

1. [Overview](./overview.md)
2. [Profiles](./profiles.md)
3. [Profiles spec](./profiles-spec.md)
4. [Site lifecycle](./site-lifecycle.md)
5. [Filesystem layout](./filesystem-layout.md)

Key topics:

- metadata and state: `nginx-metadata.md`, `site-metadata.md`
- operations model: `cron.md`, `logging-and-audit.md`
- safety model: `security-model.md`, `idempotency.md`
- implementation surfaces: `templates.md`, `os-adapters.md`
