# OS Adapters

Use this document when you need the platform abstraction boundary for package and service management.

Purpose:
- Provide a thin abstraction over package manager and service control so adding new OS families (e.g., Debian) requires minimal changes to business logic.

Coverage:
- Package commands (apt): update, install, install .deb, add PPA.
- Service control (systemd/service): enable/disable, reload/restart, daemon-reload, is-active.

Current state:
- Only Ubuntu adapter is implemented (`lib/os_adapter.sh` + `lib/os/ubuntu.sh`).
- OS support matrix is unchanged: Ubuntu 22.04/24.04, enforced by `lib/platform.sh`.

Extending:
- Add a new adapter file under `lib/os/` (e.g., `lib/os/debian.sh`) and expand `os_adapter_init` to source it when `PLATFORM_OS_ID` matches.
- Keep adapters minimal and side-effect free; callers are responsible for printing/logging.

Related docs:

- [architecture/overview.md](./overview.md)
- [architecture/security-model.md](./security-model.md)
