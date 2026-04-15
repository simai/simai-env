# PHP

Use this section for server-level PHP runtime management.

Menu items:

- [List PHP versions](./list-php-versions.md)
- [Install PHP version](./install-php-version.md)
- [Reload / restart PHP-FPM](./reload-restart-php-fpm.md)

Use `Sites -> Change site PHP` when the change is about one site. Use `PHP` when the change is about available runtimes on the server itself.

Typical flow:

1. `List PHP versions`
2. `Install PHP version` if the required runtime is missing
3. `Sites -> Change site PHP` for the actual site
4. `Diagnostics -> Site health check`

Technical reference:

- [php command reference](../../developer/commands/php.md)
