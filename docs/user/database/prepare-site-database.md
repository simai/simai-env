# Prepare Site Database

Use this item to create or repair the managed database and DB user for one site.

Choose it when:

- the profile needs a DB and site creation skipped it,
- application setup is waiting for managed credentials,
- you want to return to the supported managed path instead of hand-made DB objects.

What happens:

- the DB and user are created or reused,
- grants are repaired if needed,
- managed credentials are written into the site's `db.env`.

What to expect:

- this prepares the DB side,
- application files still may need `.env` export or product-specific setup.

Next step:

- [Write DB credentials to project .env](./write-db-credentials-to-project-env.md) if the application expects them there.
