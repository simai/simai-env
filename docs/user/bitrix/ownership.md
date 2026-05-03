# Bitrix File Ownership

Bitrix must be able to update, remove, and create files as the site runtime user.

If modules, cache files, uploads, or restored files become owned by `root`, Bitrix may fail to update, delete, or regenerate them later.

## Typical Symptoms

- module installed through Bitrix UI cannot be removed
- module update fails with a write/delete error
- cache cannot be cleared from Bitrix admin
- restored site stops near the end with "cannot write file"
- upload or generated file cannot be replaced
- `site doctor` warns about root-owned files

These are filesystem ownership problems, not necessarily Bitrix module bugs.

## Why Root-Owned Files Are Dangerous

Bitrix web operations run under the site PHP-FPM/web user context. If a file is owned by `root:root`, web code usually cannot remove or overwrite it.

Common ways root-owned files appear:

- archive restored or unpacked as `root`
- module files copied manually as `root`
- console commands executed from the project as `root`
- developer edits production files through root shell
- deployment tool leaves generated files with wrong owner

## When To Run The Check

Run ownership check:

- after restoring a Bitrix archive
- after installing or removing modules
- after copying files manually
- after running any one-off command as `root`
- when Bitrix cannot delete cache, modules, uploads, or generated files
- before handing a migrated site to developers

## Menu Flow

```text
Applications -> Bitrix -> Bitrix ownership
```

If the menu offers an apply/repair action, review the plan first and confirm only when the domain is correct.

## CLI Check

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
```

This is read-only. It reports root-owned files that can block Bitrix operations.

`site doctor` also warns about root-owned files:

```bash
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

## CLI Repair

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain> --apply yes --confirm yes
```

Repair mode changes:

- web files under the Bitrix docroot to `simai:www-data`
- managed git checkout targets under SIMAI web/git paths to `simai:simai`

The command is domain-scoped. Always check the domain before applying.

## After Restore

A restore can bring mixed ownership from the source server or unpack files as the wrong user.

Recommended sequence:

```bash
sudo /root/simai-env/simai-admin.sh bitrix restore-ready --domain <domain>
# complete restore.php in browser
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain> --apply yes --confirm yes
sudo /root/simai-env/simai-admin.sh bitrix finalize --domain <domain> --confirm yes
sudo /root/simai-env/simai-admin.sh site doctor --domain <domain>
```

If the restore wizard fails because it cannot write a file, repair ownership and retry from the restore step that failed when it is safe to do so.

## After Module Install Or Remove

If Bitrix installs a module from the web UI, files should not become `root:root`.

If they do, check:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
```

Repair if needed:

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain> --apply yes --confirm yes
```

Then retry the module operation in Bitrix.

## Cache And Uploads

Ownership problems often appear in:

```text
public/bitrix/cache
public/bitrix/managed_cache
public/bitrix/stack_cache
public/upload
public/local/modules
public/bitrix/modules
```

Do not make cache or upload directories globally writable as a workaround. Fix ownership instead.

## Use Project Access Instead Of Root

For developer file access, prefer managed project access:

```text
Access -> Create project access
```

CLI:

```bash
sudo /root/simai-env/simai-admin.sh access create-project --domain <domain> --login <login>
```

Project access is SFTP-only and scoped to one site. It is safer than giving developers `root` or the main `simai` account.

Use root only for server administration, not for routine editing of Bitrix project files.

## What Not To Do

Do not fix Bitrix permissions by blindly running:

```bash
chmod -R 777 <site>
```

Do not change the whole project to a random developer user.

Do not leave production module/cache/upload files owned by `root`.

## Handoff Checklist

Before saying ownership is healthy:

- `bitrix ownership` reports no blocking root-owned files
- `site doctor` has no ownership-related failure/warning
- Bitrix can install/remove/update the module that failed before
- cache clear works if cache was the symptom
- developers use project access or deployment flow instead of root shell edits
