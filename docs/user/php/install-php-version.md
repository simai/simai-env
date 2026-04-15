# Install PHP Version

Use this item to add a new PHP runtime to the server.

Choose it when:

- a project needs a PHP version that is not yet installed,
- you want the version to appear in site creation or PHP switching flows.

What happens:

- `simai-env` installs the selected runtime and common packages,
- validates PHP-FPM,
- enables the service.

What to expect:

- this is a server-level change,
- after installation you still need `Sites -> Change site PHP` for an existing site.
