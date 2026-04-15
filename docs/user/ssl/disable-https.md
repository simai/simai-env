# Disable HTTPS

Use this item when the site must return to HTTP-only mode or when the current certificate must be removed from active config.

Choose it when:

- certificate configuration must be rolled back,
- the domain should temporarily serve HTTP only,
- you are replacing the HTTPS strategy.

What happens:

- nginx returns to HTTP-only configuration,
- optional certificate file deletion is a separate destructive choice.

What to expect:

- user-facing HTTPS access stops working,
- this is a deliberate rollback step, not a generic fix for certificate errors.
