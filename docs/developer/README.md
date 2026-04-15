# Developer Guide

This section is for people who:

- develop `simai-env` itself,
- extend profiles and architecture,
- integrate external automation or services with the CLI,
- need exact command syntax, flags, contracts, and internal behavior.

Use this section when you need:

- internal architecture and source-of-truth models,
- exact CLI commands, flags, and contracts,
- contributor and profile-development workflows,
- runbooks for operations and rollout,
- testing and installer notes.

Recommended reading order:

1. [Architecture overview](./architecture/overview.md)
2. [Admin CLI overview](./admin.md)
3. [Command reference](./commands/README.md)
4. [Development notes](./development/README.md)
5. [Operations runbooks](./operations/README.md)

## Recommended Reading By Role

If you are changing the product itself:

1. [Architecture overview](./architecture/overview.md)
2. [Profiles architecture](./architecture/profiles.md)
3. [Development notes](./development/README.md)
4. Relevant command docs in [./commands/README.md](./commands/README.md)

If you are integrating with the CLI from scripts or external systems:

1. [Admin CLI overview](./admin.md)
2. Relevant command docs in [./commands/README.md](./commands/README.md)
3. [Operations runbook](./operations/runbook.md)

If you are adding or changing profiles:

1. [Profiles architecture](./architecture/profiles.md)
2. [Profiles spec](./architecture/profiles-spec.md)
3. [How to add profile](./development/how-to-add-profile.md)
4. [Profiles development](./development/profiles-development.md)

## Structure

- `architecture/`: internal models, metadata, filesystem layout, profiles, versioning
- `commands/`: CLI commands, options, behavior, non-interactive usage
- `development/`: contributor workflows, release process, profile authoring
- `operations/`: operator and rollout runbooks for real environments
- `admin.md`: overview of the admin CLI, menu/backend behavior, automation-facing notes
- `internal/`: temporary planning, audit, and regression notes that are not part of the main product docs

Use this section for engineering work.
If you need the menu-oriented operator manual, continue with [../user/README.md](../user/README.md).
