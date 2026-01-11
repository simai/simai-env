# Versioning

- VERSION file stores the current version; bump for any user-visible change (at least patch).
- CHANGELOG.md is reverse chronological (newest first) with date stamps.
- Major/minor changes reflect behavior/feature shifts; patch for fixes/UX/docs.
- Releases must update docs when behavior, security defaults, or UX change.
- Install/update scripts read VERSION for display and consistency.
