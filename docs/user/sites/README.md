# Sites

This is the main section for creating and controlling a site as an object managed by `simai-env`.

Use `Sites` when you need to:

- create a new site,
- inspect one site's managed metadata,
- understand activity and optimization posture,
- pause or resume runtime,
- switch PHP version,
- remove a site.

Menu items:

- [List sites](./list-sites.md)
- [Create site](./create-site.md)
- [Site info](./site-info.md)
- [Activity & optimization](./activity-and-optimization.md)
- [Change activity class](./change-activity-class.md)
- [Site availability](./site-availability.md)
- [Pause site](./pause-site.md)
- [Resume site](./resume-site.md)
- [Change site PHP](./change-site-php.md)
- [Remove site](./remove-site.md)

Advanced mode adds per-site automatic optimization override controls. Use them only when one site must opt out of the global policy.

Typical flow:

1. `Create site`
2. `Site info`
3. `SSL`
4. `Database` if needed
5. `Applications`
6. `Diagnostics -> Site health check`

Use another section instead when:

- the site already exists and you only need HTTPS: `SSL`
- the site already exists and you only need DB credentials: `Database`
- the site already exists and you need product-specific setup: `Applications`

Technical reference:

- [site command reference](../../developer/commands/site.md)
- [profile ops matrix](../../developer/operations/profile-ops-matrix.md)
