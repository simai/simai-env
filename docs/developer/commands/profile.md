# `profile` Commands

Run with `sudo /root/simai-env/simai-admin.sh profile <command> [options]` or via menu.

Use this group to inspect which profiles exist, which ones are enabled, and where they are in use.

## list
Show available profiles and activation state.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh profile list
sudo /root/simai-env/simai-admin.sh profile list --all yes
```

By default, only enabled profiles are listed. `--all yes` also shows disabled ones.

## used-by
Show which sites use profiles.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh profile used-by
sudo /root/simai-env/simai-admin.sh profile used-by --id wordpress
```

## used-by-one
Show sites using one specific profile.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh profile used-by-one --id laravel
```

## validate
Lint profile files in read-only mode.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh profile validate
sudo /root/simai-env/simai-admin.sh profile validate --all yes
```

It exits non-zero when validation finds `FAIL` items.

## enable
Enable one profile in the allowlist.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh profile enable --id wordpress
```

## disable
Disable one profile in the allowlist.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh profile disable --id wordpress
sudo /root/simai-env/simai-admin.sh profile disable --id wordpress --force yes
```

Notes:
- core profiles cannot be disabled safely without force
- profiles in active use are protected unless forced

## init
Initialize the profile allowlist.

Typical use:
```bash
sudo /root/simai-env/simai-admin.sh profile init
sudo /root/simai-env/simai-admin.sh profile init --mode all --force yes
```

Options:
- `--mode core|all`
- `--force yes|no`

Behavior:
- creates `/etc/simai-env/profiles.enabled`
- `core` keeps core profiles plus profiles already used by existing sites
- `all` seeds all current profiles

## Notes
- If `/etc/simai-env/profiles.enabled` is missing, simai-env works in legacy mode where all profiles are treated as enabled.
- `site add` only offers enabled profiles in normal selection flows.
