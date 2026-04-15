# Pause Site

Use this item when the site should stay registered but stop consuming normal runtime resources.

Choose it when:

- the site is temporarily not needed,
- you want to reduce footprint for an idle project,
- the site should clearly show a managed unavailable state instead of running half-broken.

What happens:

- the runtime is suspended,
- the PHP-FPM pool is disabled,
- cron and queue footprint are disabled when applicable,
- nginx is parked behind a managed unavailable response.

What users should expect:

- the site no longer behaves as a live application,
- this is reversible,
- metadata stays intact.

Use this instead of:

- deleting the site,
- stopping random services by hand.

Next safe step:

- [Resume site](./resume-site.md) when the site should go live again.
