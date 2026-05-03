# Bitrix Database

Bitrix usually needs a database. simai-env can create a managed MySQL database/user for a site or let you continue without DB setup for migration scenarios.

## During Site Creation

For a fresh Bitrix install, choose:

```text
Database setup for this site -> create-managed-db
```

This creates or reuses the managed DB/user for the site and stores credentials in:

```text
/etc/simai-env/sites/<domain>/db.env
```

For restore or migration where the database already exists, choose:

```text
Database setup for this site -> continue-without-db
```

Use this only when you intentionally plan to restore/connect the DB later. Do not create a new empty DB over a database that already contains production data.

## Managed DB

Managed DB is best when:

- this is a new Bitrix site
- the environment should generate DB name, user, and password
- future site-scoped DB commands should operate on this DB

Useful checks:

```bash
sudo /root/simai-env/simai-admin.sh site db-status --domain <domain>
sudo /root/simai-env/simai-admin.sh site info --domain <domain>
```

If DB was skipped during creation and you want to create it later:

```bash
sudo /root/simai-env/simai-admin.sh site db-create --domain <domain>
```

In CLI apply mode:

```bash
sudo /root/simai-env/simai-admin.sh site db-create --domain <domain> --confirm yes
```

## Existing DB Or Restore DB

Use an existing DB path when:

- restoring a production archive
- moving a Bitrix site from another server
- DB name/user/password must stay compatible with an existing backup

In this case, keep a clear note of:

- DB host
- DB name
- DB user
- DB password
- charset and collation if known

Then follow the restore wizard or Bitrix configuration path for those credentials.

## DB Preseed For Installer

For managed DB sites, Bitrix helper commands can write Bitrix DB config files from `db.env`.

Fresh installer flow:

```bash
sudo /root/simai-env/simai-admin.sh bitrix installer-ready --domain <domain>
```

Restore flow:

```bash
sudo /root/simai-env/simai-admin.sh bitrix restore-ready --domain <domain>
```

These commands do not print DB password to the console.

## Export To Project Env

The generic site DB export command writes `DB_*` values into a target file under the project directory:

```bash
sudo /root/simai-env/simai-admin.sh site db-export --domain <domain>
```

For Bitrix, the important application files are usually Bitrix-specific config files under `bitrix/.settings.php` and `bitrix/php_interface/dbconn.php`; use Bitrix installer/restore/finalize commands when possible.

## Rotate Password

To rotate the managed DB user password:

```bash
sudo /root/simai-env/simai-admin.sh site db-rotate --domain <domain>
```

After rotation, make sure the Bitrix application config is updated as part of the same operation. Otherwise the site may keep trying to connect with the old password.

## Successful Result

Healthy managed DB state:

- `site db-status` shows DB/user/grants present
- Bitrix installer or restore wizard can connect
- `bitrix status` reports installed state after browser setup
- `site doctor` has no DB-related failure

## Common Mistakes

- Creating a new empty managed DB when the restore should use an existing DB with data.
- Rotating DB password without updating Bitrix config.
- Treating `/etc/simai-env/sites/<domain>/db.env` as the same thing as Bitrix application config. It is the environment source of truth; Bitrix still needs its own config files.
