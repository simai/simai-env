---
extends: _core._layouts.documentation
section: content
title: simai-env Documentation
description: Start here for user workflows, developer reference, architecture, and operations.
---

# simai-env Documentation

`simai-env` is a menu-first environment manager for PHP projects on Ubuntu. This site publishes the repository documentation in a navigable format for two main audiences.

## Choose Your Path

- [User Guide](user/): work through the interactive menu, choose the right site profile, and complete standard operator workflows.
- [Developer Guide](developer/): understand architecture, CLI contracts, profile design, operations runbooks, and implementation details.

## What This Site Covers

- creating and managing sites through the admin menu
- profile-specific operator documentation for Generic, Static, Alias, Laravel, WordPress, and Bitrix
- CLI command reference for `simai-admin.sh`
- architecture details, metadata contracts, filesystem layout, and templates
- operational runbooks and production readiness checklists

## Repository Quick Start

Install and open the menu:

```bash
curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo bash
sudo /root/simai-env/simai-admin.sh menu
```

For code and release work, see the repository on GitHub: [simai/simai-env](https://github.com/simai/simai-env).
