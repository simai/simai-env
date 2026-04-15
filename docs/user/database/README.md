# Database

Use this section for managed MySQL operations that belong to one site or to server DB visibility.

Menu items:

- [List databases](./list-databases.md)
- [Database server status](./database-server-status.md)
- [Prepare site database](./prepare-site-database.md)
- [Write DB credentials to project .env](./write-db-credentials-to-project-env.md)
- [Rotate database password](./rotate-database-password.md)

Advanced mode adds database removal for one site.

Typical flow:

1. `Database server status`
2. `Prepare site database`
3. `Write DB credentials to project .env`
4. Continue in `Applications` if the product still needs installer or finalize steps

Use another section instead when:

- you need to create the site shell first: `Sites`
- the DB is healthy and the issue is application-level: `Applications` or `Diagnostics`

Technical reference:

- [database command reference](../../developer/commands/db.md)
