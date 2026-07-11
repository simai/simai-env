# simai-env

Minimal two-step setup for PHP projects on Ubuntu 22.04/24.04. No demo sites are created automatically.

## Quick start (run as root)
1) Install scripts and base packages (auto-opens menu on interactive terminals):
```bash
curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo bash
```
2) If the menu did not open automatically, start it manually:
```bash
sudo /root/simai-env/simai-admin.sh menu
```

CLI help is generated from the command registry:
```bash
sudo /root/simai-env/simai-admin.sh help
sudo /root/simai-env/simai-admin.sh help site
```

On first run the menu may offer to install required packages (bootstrap). Accepting will install nginx/php/mysql/node/certbot and related utilities without touching your sites.

Scripts only (no bootstrap during install):
```bash
curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo env SIMAI_INSTALL_MODE=scripts bash
```

## Notes
- User/project defaults: user `simai`, home `/home/simai`, projects `/home/simai/www/<domain>/` (slug used for IDs: pool/cron/socket/logs).
- Profiles: generic, laravel, static, alias (set via admin CLI).
- Healthcheck endpoints are local-only by default.
- Reserved domains (RFC 2606) are blocked unless explicitly allowed.
- Do not put credentials directly into reusable shell snippets or documentation;
  prefer interactive prompts and protected environment/config files.

## Local checks
Run CI checks locally:
```bash
bash scripts/ci/run.sh
```
ShellCheck runs with warnings treated as errors to prevent regressions.
You can point `SHELLCHECK_BIN` to a custom binary if not in PATH.

## More docs
- Releases: `docs/releases/README.md`
- Docs entrypoint: `docs/README.md`
- User documentation: `docs/user/README.md`
- User profile workflows: `docs/user/profile-workflows.md`
- Bitrix user workflows: `docs/user/bitrix/README.md`
- Daily ops quickstart: `docs/operations/daily-ops-quickstart.md`
- Profile ops matrix: `docs/operations/profile-ops-matrix.md`
- Bitrix production runbook: `docs/operations/bitrix-production-runbook.md`
- WordPress production runbook: `docs/operations/wordpress-production-runbook.md`
- Operator runbook: `docs/operations/runbook.md`
- Architecture overview: `docs/architecture/overview.md`
- Admin commands: `docs/commands/`
- Advanced/legacy installer flags: `docs/advanced-installer.md`
- Contribution and license: see `CONTRIBUTING.md` and `LICENSE`.
