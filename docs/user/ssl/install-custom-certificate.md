# Install Custom Certificate

Use this item when the certificate and private key come from outside Let's Encrypt.

Choose it when:

- the customer provides a purchased certificate,
- company policy requires a specific issuer,
- you already have ready certificate files.

What happens:

- certificate files are copied into the managed nginx SSL area,
- nginx is updated to use them,
- HTTPS redirect and HSTS options can be applied at the same time.

What to expect:

- use this instead of manual nginx edits,
- verify the result with `Certificate status`,
- renewals for custom certs stay your responsibility unless you replace them later with Let's Encrypt.
