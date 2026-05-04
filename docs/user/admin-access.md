# Admin Access Model

SIMAI ENV separates server administration, site runtime, and developer file
access. This avoids one account becoming both the web runtime and the system
administrator.

## Recommended Roles

| Account | Purpose | Human workflow |
| --- | --- | --- |
| `root` | Owner-level system administration | Trusted owner/admin only, SSH key-only |
| `simai-admin` | Optional hardened sudo operator | Use when daily root login is disallowed |
| `simai` | Internal runtime user for sites | Do not use as a human admin login |
| Access users | Developer/content SFTP access | Scoped to all sites or one project |

## Simple Admin Mode

Use this mode for small installations and owner-operated servers.

- `root` can log in only by SSH key.
- Password and keyboard-interactive SSH login should be disabled.
- The menu runs directly as root:

```bash
/root/simai-env/simai-admin.sh menu
```

This mode works well with GUI SFTP tools such as Transmit and WinSCP because the
trusted owner can inspect or edit system files when needed.

Do not give root access to developers. Use managed Access users for that.

## Hardened Admin Mode

Use this mode when an organization does not want daily work under `root`.

- `simai-admin` is created as a sudo operator.
- `root` remains key-only emergency access.
- The menu runs through sudo:

```bash
ssh simai-admin@<server>
sudo /root/simai-env/simai-admin.sh menu
```

This is safer for auditability, but it is less convenient for GUI SFTP tools
because they usually cannot edit files through sudo.

## Why Not Give `simai` Sudo

`simai` is the runtime account for sites:

- PHP-FPM pools run as `simai`;
- cron/agents can run as `simai`;
- site files under `/home/simai/www` are owned by `simai`;
- Composer, WP-CLI and similar project commands may run as `simai`.

If `simai` receives sudo, a web application compromise becomes much closer to a
full server compromise. Keep `simai` as an internal runtime user.

## Working With Files

Use the account that matches the task:

| Task | Recommended account |
| --- | --- |
| Edit nginx, SSH, system configs, `/root/simai-env` | `root` key-only |
| Open the admin menu in simple mode | `root` |
| Open the admin menu in hardened mode | `simai-admin` + `sudo` |
| Upload or edit files for one site | project Access user |
| Give developer access to all sites | global Access user |
| Repair Bitrix file ownership | menu or `bitrix ownership` command |

Do not upload site files as `simai-admin`. Those files can get the wrong owner
and later become hard for Bitrix/PHP to update or remove.

## Check Current Mode

Run:

```bash
sudo /root/simai-env/simai-admin.sh self admin-mode-status
```

Typical modes:

- `simple-root-key-only`: root key-only is the main admin path; no sudo operator
  is required.
- `hardened-sudo-admin`: `simai-admin` is ready and root remains key-only.
- `password-login-enabled`: password SSH is still enabled and should usually be
  hardened.
- `custom`: SSH settings do not match a managed profile.

## Practical Recommendation

For most owner-operated SIMAI ENV servers:

1. Keep root SSH key-only.
2. Disable password SSH login.
3. Use root for trusted system administration and GUI SFTP system edits.
4. Use Access users for developers.
5. Keep `simai` runtime-only.
6. Enable `simai-admin` only when a stricter admin workflow is required.
