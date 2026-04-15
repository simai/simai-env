# Advanced installer options

The primary path is to install scripts and use the admin menu. If you need non-default flags or scripted installs, `simai-env.sh` supports the same options as before.

## Examples

- Install with custom paths and pinned tag:
```bash
curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/install.sh | \
  REF=refs/tags/vX.Y.Z INSTALL_DIR=/opt/simai-env sudo -E bash
```

- Install a new project directly (non-menu):
```bash
sudo /root/simai-env/simai-env.sh --domain your-domain.tld --project-name myapp \
  --db-name myapp --db-user simai --db-pass secret --php 8.2 --run-migrations --optimize
```

- Configure an existing project:
```bash
sudo /root/simai-env/simai-env.sh --existing --path /home/simai/www/myapp \
  --domain app.local --php 8.3
```

- Cleanup (destructive; requires --confirm):
```bash
sudo /root/simai-env/simai-env.sh clean --project-name myapp --domain your-domain.tld \
  --remove-files --drop-db --drop-db-user --confirm
```

## Notes
- Reserved domains (RFC 2606) remain blocked unless explicitly allowed.
- Installer logs to `/var/log/simai-env.log` (override with `--log-file`).
- No demo sites are created automatically; existing nginx configs are left untouched.
