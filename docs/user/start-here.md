# Start Here

Launch the menu:

```bash
sudo /root/simai-env/simai-admin.sh menu
```

Before touching a production site, keep this mental model:

1. `Sites` creates and controls the site container: domain, profile, runtime state, PHP binding.
2. `SSL` turns HTTPS on or changes certificates.
3. `Database` creates and rotates managed DB credentials for the site.
4. `Applications` finishes Laravel, WordPress, or Bitrix lifecycle after the site already exists.
5. `Diagnostics` tells you whether the current state is healthy.
6. `Logs` helps when something already went wrong.
7. `System` is for the platform itself, not for one site.

What the menu does well:

- stays open after each action,
- asks for required values like `domain` or `php`,
- safely treats cancel as cancel,
- hides more dangerous maintenance under Advanced mode.

What a new operator should do first:

1. Open `System -> Platform status` and make sure the host is healthy.
2. Open `Profiles -> List profiles` and confirm the needed profile is enabled.
3. Only then open `Sites -> Create site`.

Common mistake to avoid:

- Do not start with `Applications` before the site exists.
- Do not start with `Logs` when you still do not know whether the environment is healthy.
- Do not use `Repair` or other apply actions before you have a read-only check from `Diagnostics`.
