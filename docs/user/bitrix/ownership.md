# Bitrix File Ownership

Bitrix must be able to update, remove, and create files as the site runtime user.

If modules, cache files, or restored files become `root:root`, Bitrix may fail to update or remove files later.

## Check

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain>
```

## Repair

```bash
sudo /root/simai-env/simai-admin.sh bitrix ownership --domain <domain> --apply yes --confirm yes
```

`site doctor` also warns about root-owned files.

## When To Run

- after restoring a Bitrix archive
- after installing or removing modules
- after manual file operations as `root`
- when Bitrix cannot delete cache, modules, uploads, or generated files
