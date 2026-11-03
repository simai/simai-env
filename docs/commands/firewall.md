# firewall, panel access and timed changes

Run with `sudo /root/simai-env/simai-admin.sh <section> <command> [options]`.
The firewall is ufw, set up first with `self firewall-ensure` (see
[self](self.md)).

## Timed changes

Every command below that changes the firewall or panel access is a **timed
change**:

1. the current files are saved (`/etc/ufw/user.rules`, `user6.rules`, the
   block list; for panel access the panel's nginx file and its access file);
2. the change is applied;
3. unless `change confirm --id <id>` comes within `--window` seconds (30-600,
   default 120), a timer puts the saved files back.

A change that cuts off whoever made it therefore undoes itself. If the timer
is lost (a reboot), the five-minute `self status-refresh` undoes it. Only one
change of a kind waits for confirmation at a time.

```bash
sudo /root/simai-env/simai-admin.sh firewall rule-add --port 8080 --proto tcp --confirm yes
# | Change | 3f9c2a7b10de | ... | Confirm | simai-admin.sh change confirm --id 3f9c2a7b10de --confirm yes
sudo /root/simai-env/simai-admin.sh change confirm --id 3f9c2a7b10de --confirm yes
```

- `change status --id ID [--output json]` — `simai-change/1`: `change_id`,
  `kind` (`firewall` or `panel_access`), `domain`, `state`
  (`pending|confirmed|restored`), `summary`, `created_at`, `expires_at`,
  `confirmed_at`, `restored_at`.
- `change restore --id ID` — undo a pending change now.
- `change expire` — undo changes past their deadline and end expired blocks
  (run by the status refresh).

## firewall status

`firewall status [--output json]` — `simai-firewall/1`: `backend` (ufw),
`active`, `default_incoming`, `ssh_ports`, `rules [{id, rule, action, port,
proto, from, direction, protected}]`, `blocks [{address, until, created_at}]`,
`panel_access {domain, allow: "any" | [addresses]}` (null without a panel),
`pending_change` (the change waiting for confirmation, or null).

A rule id is stable for the same rule text. `protected` rules keep SSH,
HTTP or HTTPS open for everyone.

## firewall rule-add / rule-remove

- `firewall rule-add --port P --proto tcp|udp [--from any|ADDRESS|CIDR]
  [--action allow|deny] [--window S]`
- `firewall rule-remove --id ID [--window S]`

Deny rules go before the allow rules. SSH ports, 80 and 443 cannot be denied
for everyone, and their allow rules cannot be removed.

## firewall block / unblock

- `firewall block --address ADDRESS|CIDR [--ttl SECONDS] [--window S]` — deny
  everything from it; `--ttl` 60-31536000 ends the block by itself (0 or none:
  until unblocked).
- `firewall unblock --address ADDRESS|CIDR [--window S]`

IPv4 and IPv6.

## panel access

`panel access --allow any|ADDR[,ADDR...] [--window S]` — only these addresses
or CIDR blocks (up to 50) open the panel site; `any` removes the limit. Written
to `/etc/nginx/simai-access/<project>.conf`, which every site's nginx file
includes; the host itself (127.0.0.1, ::1) and certificate checks
(`/.well-known/acme-challenge/`) always get through.
