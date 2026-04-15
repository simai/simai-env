# Resume Site

Use this item to restore a previously suspended site's runtime.

Choose it when:

- the site was intentionally paused earlier,
- maintenance is over,
- an idle project should become live again.

What happens:

- managed runtime pieces are re-enabled,
- nginx returns to the normal site config,
- related PHP, cron, and queue pieces come back when the profile uses them.

What to expect:

- this action is meant for a site that was paused through the menu,
- if the application is still broken after resume, continue with `Diagnostics` and `Applications`, not with repeated resume attempts.
