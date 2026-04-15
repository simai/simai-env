# Rotate Database Password

Use this item when the managed DB password for a site must change.

Choose it when:

- credentials may be compromised,
- password rotation is part of maintenance policy,
- the site is being handed over.

What happens:

- a new DB password is generated or applied,
- the site's managed DB credentials are updated,
- in menu mode you can also sync the new password into the project `.env`.

What to expect:

- the application can break if its `.env` is left with the old password,
- update the project config immediately after rotation if the application uses `.env`.
