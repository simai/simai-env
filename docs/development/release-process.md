# Release Process

1. Update code and ensure behavior changes are reflected in docs (`docs/architecture/*`, `docs/commands/*`, `docs/admin.md`, `README.md`).
2. Bump VERSION and prepend CHANGELOG.md with date (reverse chronological).
3. Run lint/static checks (`bash -n` on touched scripts).
4. Verify no secrets in logs; ANSI output remains TTY-only.
5. If profiles change, update registry files and profile docs; ensure menu selection still works.
6. Tag/release when ready; install/update scripts reference VERSION for display.
