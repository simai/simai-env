# Create Site

Use this item to create a new managed site with nginx wiring, profile metadata, and optional DB, SSL, and access bootstrap.

Choose it when:

- the domain is new to this server,
- you want `simai-env` to own the site's runtime and metadata,
- you know which profile the site should use.

The wizard typically asks:

- domain,
- profile,
- whether the site should also serve first-level subdomains,
- activity class,
- PHP version if the profile requires PHP,
- whether to issue Let's Encrypt now,
- whether to prepare a managed DB now,
- whether to create project access now.

What happens after confirmation:

- the project path is created under the managed root,
- nginx and PHP-FPM wiring is prepared when the profile needs it,
- profile markers and placeholders are created,
- optional DB and SSL steps run if you chose them.

What to expect after success:

- the site exists in `List sites`,
- `Site info` shows the managed paths and next steps,
- for Laravel, WordPress, and Bitrix you still need the `Applications` section.

Use this item instead of:

- editing nginx by hand,
- creating an unmanaged directory and trying to attach it later through the normal menu.

Then continue with:

1. [Site info](./site-info.md)
2. `SSL`
3. `Database`
4. `Applications`
