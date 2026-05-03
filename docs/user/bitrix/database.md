# Bitrix Database

During site creation, the menu can create a managed MySQL database and user.

Use managed DB when the environment should own the database credentials and write them into the site metadata.

Use an existing database when restoring or connecting to a database that already has data. In that case, do not recreate it blindly; use the restore wizard or application configuration path that matches the backup.

## After DB Changes

Check:

```bash
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
sudo /root/simai-env/simai-admin.sh bitrix status --domain <domain>
```

If credentials are rotated later, make sure Bitrix configuration is updated as part of the same operation.
