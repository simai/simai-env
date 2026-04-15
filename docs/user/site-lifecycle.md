# Site Lifecycle

The normal lifecycle in `simai-env` is:

1. Create the site in `Sites`.
2. Prepare HTTPS in `SSL`.
3. Prepare managed DB in `Database` if the profile needs it.
4. Finish CMS or framework setup in `Applications`.
5. Validate with `Diagnostics`.
6. Use `Logs` only if validation or the application still shows errors.

Typical flows:

`generic`
- create site,
- issue SSL if needed,
- export DB credentials if the project uses DB,
- deploy application code,
- run `Diagnostics -> Site health check`.

`laravel`
- create site with profile `laravel`,
- `Applications -> Laravel status`,
- `Applications -> Laravel prepare app`,
- deploy or sync the real code if needed,
- `Applications -> Laravel complete setup`,
- `Diagnostics -> Site health check`.

`wordpress`
- create site with profile `wordpress`,
- prepare DB,
- in Advanced mode run `Applications -> WordPress installer ready`,
- finish the web installer,
- `Applications -> WordPress complete setup`,
- `Diagnostics -> Site health check`.

`bitrix`
- create site with profile `bitrix`,
- prepare DB,
- in Advanced mode run `Applications -> Bitrix installer ready`,
- finish the web installer,
- `Applications -> Bitrix complete setup`,
- `Diagnostics -> Site health check`.

The key rule: `Sites` creates the managed shell, `Applications` completes the product-specific internals.
