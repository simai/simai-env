# Applications

Use this section only after the site already exists.

Submenus:

- [Laravel](./laravel/README.md)
- [WordPress](./wordpress/README.md)
- [Bitrix](./bitrix/README.md)

Mental model:

- `Sites` creates the managed shell,
- `Database` and `SSL` prepare shared infrastructure,
- `Applications` finishes product-specific lifecycle.

Use `Applications` when the site exists but the framework or CMS still needs preparation, finalization, scheduler alignment, or product-specific status checks.

Typical flow:

1. create the site in `Sites`
2. prepare DB and HTTPS if needed
3. open the product submenu here
4. run the product status page first
5. run installer or finalize actions only for that product

Use another section instead when:

- the site shell itself does not exist yet: `Sites`
- the failure is still generic and not product-specific: `Diagnostics`
