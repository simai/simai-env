# Write DB Credentials To Project .env

Use this item to copy managed DB credentials into the site's application `.env`.

Choose it when:

- the DB is already prepared,
- the application reads DB settings from `.env`,
- DB password was rotated and the project file must be updated.

What happens:

- `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, and `DB_PASSWORD` are written or updated idempotently in the project file.

What to expect:

- this does not create the DB,
- this does not run migrations,
- after export, continue with framework or CMS setup in `Applications`.
