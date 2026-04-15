# Renew Certificate

Use this item to force renewal for one managed Let's Encrypt certificate.

Choose it when:

- expiry is approaching and you want to validate the renewal path now,
- the previous automated renewal did not happen,
- certificate status suggests a stale or mismatched state.

What happens:

- `simai-env` reruns the renewal flow,
- nginx is reloaded after a successful renewal.

What to expect:

- it is narrower than full reissuance,
- if renewal fails, inspect `Certificate status` and `Logs -> Certificate log`.
