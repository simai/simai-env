# Panel gateway (draft contract)

Status: draft for SIMAI ENV Panel stage 0. Nothing here is implemented yet
except the read-only commands and recordings listed under "Recorded answers".

SIMAI ENV Panel is a Larena application (package `larena/env`) installed by
simai-env as an ordinary site. simai-env stays the only component that
changes the host; the panel asks it through one narrow entry point, the panel
gateway, modelled on the deploy gate (`admin/deploy_gate.sh`).

## Identity

- The panel's PHP-FPM pool runs as its own system account `simai-panel`, not
  `simai` (shared sites live there) and not root.
- `simai-panel` may run exactly one program as root:
  `sudo /root/simai-env/admin/panel_gate.sh` (sudoers entry written by
  `panel install`). On another host the same gateway is the forced command of
  an SSH key, so a panel can later manage several servers.
- The gateway reads one JSON request on stdin and writes one JSON answer on
  stdout. Logs go to `/var/log/simai-panel-gate.log`; every request is also in
  `/var/log/simai-admin.log` with the panel's `request_id` as correlation id.

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
  "kind": "result", "data": { … } }
```

| `status` | Meaning |
| --- | --- |
| `ok` | `kind` is `result` (data), `plan` (what would change) or `job` (`job_id` of a long operation) |
| `refused` | not allowed: command not in the allowlist, owner scope, invalid argument; `reason` is a stable code |
| `failed` | the command ran and failed; `reason` and a sanitized `message` |

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

- stage 1: `read` commands (`self describe`, `site describe`, `site list`,
  `ssl status`, `backup inspect`, `logs *` tails, …);
- stage 2: safe actions (`ssl letsencrypt`, `site deploy`,
  `site deploy-rollback`, `backup data`, `queue restart`);
- stage 3–4: owner-scoped and creating/deleting commands.

Interactive and operator-only commands (menus, `self bootstrap`,
`access reset-password`, `self ssh-hardening-ensure`, …) are never exposed.

## Recorded answers

`testing/fixtures/panel/` holds JSON answers recorded from the local stand
(`testing/stand/stand.sh record`): `self describe`, `self commands` and
`site describe` for demo sites. The panel's fixture driver replays them, and
both sides test against the same files: simai-env checks that it still
answers in this shape, `larena/env` checks that it can display it. Re-record
after a change of the answer shape, never edit the files by hand.

## Local development

`testing/stand/stand.sh up` starts a long-lived Ubuntu container with
simai-env and demo sites (static, PHP with a database, an owner's site, a
redirect) on `127.0.0.1:18080` and SSH on `127.0.0.1:12222`. The panel can
run on the laptop with the fixture driver, and switch to the stand once the
gateway exists.
