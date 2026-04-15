# Admin CLI Overview

`simai-admin.sh` is the engineering-facing control plane for `simai-env`.

It has two interfaces:

- direct CLI: `sudo /root/simai-env/simai-admin.sh <section> <command> [options]`
- interactive menu: `sudo /root/simai-env/simai-admin.sh menu`

Use this page when you need orientation, not full command reference.

## What This Page Covers

- how the admin CLI is structured,
- how menu-driven work maps to direct CLI usage,
- where to find command-level reference,
- what contract to rely on in automation.

For exact options and flags, use [commands/README.md](./commands/README.md).
For architecture and profile internals, use [architecture/README.md](./architecture/README.md).
For operational procedures, use [operations/README.md](./operations/README.md).

## Mental Model

`simai-admin.sh` is organized by section.
The menu is only one interface over the same command registry.

The main sections are:

- `site`
- `ssl`
- `php`
- `db`
- `access`
- `logs`
- `backup`
- `profile`
- `self`
- product-specific sections such as `laravel`, `wp`, `bitrix`

The menu groups these commands into user-facing categories such as `Sites`, `SSL`, `Database`, `Applications`, and `System`.

## Menu Vs Direct CLI

Use the menu when:

- an operator needs guided prompts,
- values such as `domain` or `php` should be selected interactively,
- the task is ordinary day-to-day administration.

Use direct CLI when:

- you are automating work,
- you need stable scripts or CI integration,
- you want exact repeatability and explicit flags.

## Common Behavioral Rules

- supported OS: Ubuntu 22.04/24.04
- run as `root`
- menu cancel should be safe and non-destructive
- command output goes to stdout and also to managed logs where applicable
- many commands are profile-aware and derive behavior from site metadata

## Non-Interactive Contract

When using `simai-admin.sh` from automation:

- prefer direct CLI, not `menu`
- treat exit code `0` as success
- treat non-zero exit codes as failure
- disable colors with `NO_COLOR=1` or `SIMAI_UI_COLOR=never`

Typical pattern:

```bash
NO_COLOR=1 /root/simai-env/simai-admin.sh self status >/tmp/simai-status.txt
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "simai status failed" >&2
  exit $rc
fi
```

## Where To Go Next

- site lifecycle and project operations: [commands/site.md](./commands/site.md)
- platform-level behavior and automation: [commands/self.md](./commands/self.md)
- profile model and constraints: [architecture/profiles.md](./architecture/profiles.md)
- production rollout and daily operations: [operations/README.md](./operations/README.md)
