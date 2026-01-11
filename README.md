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

On first run the menu may offer to install required packages (bootstrap). Accepting will install nginx/php/mysql/node/certbot and related utilities without touching your sites.

Scripts only (no bootstrap during install):
```bash
SIMAI_INSTALL_MODE=scripts curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | sudo bash
```

## Notes
- User/project defaults: user `simai`, home `/home/simai`, projects `/home/simai/www/<domain>/` (slug used for IDs: pool/cron/socket/logs).
- Profiles: generic, laravel, static, alias (set via admin CLI).
- Healthcheck endpoints are local-only by default.
- Reserved domains (RFC 2606) are blocked unless explicitly allowed.
- Bash history note: if your password/command contains `!`, wrap it in single quotes (e.g., `--pass 'S3cret!pass'`) to avoid history expansion, or disable history expansion (`set +H`).

## Local checks
Run CI checks locally:
```bash
bash scripts/ci/run.sh
```
ShellCheck runs with warnings treated as errors to prevent regressions.
You can point `SHELLCHECK_BIN` to a custom binary if not in PATH.

## More docs
- Docs entrypoint: `docs/README.md`
- Architecture overview: `docs/architecture/overview.md`
- Admin commands: `docs/commands/`
- Advanced/legacy installer flags: `docs/advanced-installer.md`
- Contribution and license: see `CONTRIBUTING.md` and `LICENSE`.
