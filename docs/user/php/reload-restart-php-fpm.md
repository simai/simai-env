# Reload / Restart PHP-FPM

Use this item when a PHP-FPM service needs a controlled reload or restart.

Choose it when:

- config changed and the service must reread it,
- a PHP service is healthy enough for restart but not for deeper repair,
- support work specifically points to PHP-FPM state.

What to expect:

- this acts on a PHP version, not on one site,
- it is operational maintenance, not application troubleshooting.
