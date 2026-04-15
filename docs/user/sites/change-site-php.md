# Change Site PHP

Use this item to move one site to another installed PHP version.

Choose it when:

- the application requires a different supported PHP version,
- you are standardizing several projects on the same runtime,
- current PHP is outdated for that profile.

What the wizard asks:

- the domain,
- the target PHP version.

What happens:

- `simai-env` validates that the profile allows the target version,
- the site is rewired to a PHP-FPM pool for the new version,
- nginx upstream settings are updated,
- old pool cleanup happens unless explicitly preserved through CLI.

What to expect:

- this changes runtime behavior,
- you should run `Site info` and `Diagnostics -> Site health check` right after,
- if the product has app-specific checks, open its status page in `Applications`.
