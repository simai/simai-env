# Release Process

1. Update code and ensure behavior changes are reflected in docs (`docs/architecture/*`, `docs/commands/*`, `docs/admin.md`, `README.md`).
2. Bump VERSION and prepend CHANGELOG.md with date (reverse chronological).
3. Run lint/static checks (`bash -n` on touched scripts).
4. Run executable release gate (mandatory before release):
   - `bash testing/release-gate.sh`
   - Gate includes shell syntax checks + `testing/run-regression.sh full` on the configured test server.
5. For interactive menu changes, review `docs/development/menu-ux-audit.md` and record the affected scenario(s) before/after the change.
6. Verify no secrets in logs; ANSI output remains TTY-only.
7. If profiles change, update registry files and profile docs; ensure menu selection still works.
8. Tag/release when ready; install/update scripts reference VERSION for display.
