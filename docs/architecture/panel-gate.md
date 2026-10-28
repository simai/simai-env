# Panel gateway

Status: stage 1 (read-only) is implemented in 1.20.0 (`admin/panel_gate.py`,
`panel gate-enable|gate-disable|gate-status`, test `panel_e2e`). Plans,
long operations and owner-scoped changes below are the agreed direction for
the next stages.

SIMAI ENV Panel is a Larena application (package `larena/env`) installed by
simai-env as an ordinary site. simai-env stays the only component that
changes the host; the panel asks it through one narrow entry point, the panel
gateway, modelled on the deploy gate (`admin/deploy_gate.sh`).

## Identity

- The panel's PHP-FPM pool runs as its own system account `simai-panel`, not
  `simai` (shared sites live there) and not root.
- `simai-panel` may run exactly one program as root, without arguments:
  `sudo -n /usr/local/sbin/simai-panel-gate` (written by
  `panel gate-enable`; it runs `python3 -I admin/panel_gate.py`).
- `panel gate-enable --pubkey-file K` also lets an SSH key reach the same
  gateway as a forced command (`restrict`, no TTY or forwarding): a panel on
  another machine, the laptop stand, or later several servers.
- The gateway reads one JSON request on stdin (at most 64 KiB) and writes one
  JSON answer on stdout. Each request is a JSON line in
  `/var/log/simai-panel-gate.log` (root only): request id, actor, owner,
  command, domain, status, reason and the simai-env `operation_id`, which
  links it to `/var/log/simai-admin.log`.

## Request

```json
{
  "schema": "simai-panel-request/1",
  "request_id": "01JB…",
  "actor": { "user": "admin@example.com", "owner": null, "impersonated_by": null },
  "command": "site:describe",
  "args": { "domain": "example.com" },
  "confirm": false
}
```

- `command` is a registry key (`section:name`) from `self commands`.
- `args` maps option names without `--` to strings; unknown options are
  refused before any handler runs.
- `actor.owner` is set when the panel user is an owner (or an administrator
  acting as one): the gateway then refuses any `domain` that the owner does
  not own, and any host-level command.
- `confirm: false` on a state-changing command returns the plan only, as the
  CLI does without `--confirm yes`.

## Answer

```json
{ "schema": "simai-panel-answer/1", "request_id": "01JB…", "status": "ok",
  "kind": "result", "data": { … }, "command_status": "success",
  "operation_id": "20261028195030885137839" }
```

`data` is the command's own structured answer (`self describe`,
`site describe`, …; see `testing/fixtures/panel/`). `command_status` is the
simai-env result status: `site doctor` answers `ok` with
`command_status: failed` when a diagnostic check fails.

| `status` | Meaning |
| --- | --- |
| `ok` | `kind` is `result` (data); later also `plan` (what would change) or `job` (`job_id` of a long operation) |
| `refused` | not run; `reason`: `bad_request`, `too_large`, `bad_actor`, `not_allowed`, `invalid_argument`, `owner_scope` |
| `failed` | ran and failed; `reason`: the simai-env error code or `invalid_output` |

Secrets are never part of an answer: no `.env` values, database passwords,
private keys or deploy keys. Commands that print secrets for an operator
(for example a generated password) are not in the allowlist.

## Long operations

Commands whose effect is not `read` and that can take longer than a few
seconds (`ssl letsencrypt`, `site deploy`, `backup data`, `php install`, …)
start a transient systemd unit and answer `kind: job`. The job survives a
panel restart.

| Command | Answer |
| --- | --- |
| `job:status` `{job_id}` | `queued`, `running`, `succeeded`, `failed`, `cancelled`, current step, timestamps |
| `job:log` `{job_id, after}` | log lines after a cursor (for a live view) |
| `job:cancel` `{job_id}` | stops the unit; the command's own rollback applies |

## Allowlist

The allowlist is derived from the registry (`self commands`: effects,
confirmation, lock) and a panel policy file shipped with simai-env:

- stage 1 (implemented): `self:describe`, `self:commands`,
  `site:describe {domain}`, `site:doctor {domain, strict, include-target}`.
  An owner gets `self:describe` reduced to their own sites and is refused
  (`owner_scope`) on any other domain. `confirm` must be absent or false;
- next read commands need a structured answer first: SSL status and expiry,
  backups, log tails;
- stage 2: safe actions (`ssl letsencrypt`, `site deploy`,
  `site deploy-rollback`, `backup data`, `queue restart`);
- stage 3–4: owner-scoped and creating/deleting commands.

Interactive and operator-only commands (menus, `self bootstrap`,
`access reset-password`, `self ssh-hardening-ensure`, …) are never exposed.

## Recorded answers

`testing/fixtures/panel/` holds gateway answers recorded from the local
stand (`testing/stand/stand.sh record`): host description (also an owner's
view), command registry, `site describe` and `site doctor` for demo sites,
and two refusals. The panel's fixture driver replays them, and
both sides test against the same files: simai-env checks that it still
answers in this shape, `larena/env` checks that it can display it. Re-record
after a change of the answer shape, never edit the files by hand.

## Local development

`testing/stand/stand.sh up` starts a long-lived Ubuntu container with
simai-env and demo sites (static, PHP with a database, an owner's site, a
redirect) on `127.0.0.1:18080`, and enables the gateway for the key
`~/.simai-stand/panel_ed25519`. The panel can run on the laptop with the
fixture driver, and switch to the stand with the same requests:

```bash
printf '%s' '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"me","owner":null},"command":"self:describe","args":{}}' \
  | ssh -i ~/.simai-stand/panel_ed25519 -p 12222 simai-panel@127.0.0.1
```
