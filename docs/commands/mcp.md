# MCP: AI assistants manage the server

`mcp` lets an AI assistant (Claude, Codex, Cursor or any other MCP client)
work with this server the way a person works in the panel: read the state of
sites and the server, plan a change, show the plan, and run it after the
person agreed. It goes through the panel gateway
(`docs/architecture/panel-gate.md`), with the same roles, the same checks of
every argument and the same audit log.

```bash
simai-admin.sh mcp enable --confirm yes
simai-admin.sh mcp key-add --pubkey-file ai.pub --owner acme --confirm yes   # acme's sites
simai-admin.sh mcp key-add --pubkey-file ai.pub --admin yes --confirm yes    # the whole server
simai-admin.sh mcp status
```

Then on the computer with the assistant (the private key of `ai.pub` must be
there, e.g. in `~/.ssh` or an SSH agent):

```bash
claude mcp add simai -- ssh -T simai-mcp@server.example.com
codex mcp add simai -- ssh -T simai-mcp@server.example.com
```

Other clients take the JSON shown by `mcp status`:
`{"mcpServers": {"simai": {"command": "ssh", "args": ["-T", "simai-mcp@server"]}}}`.
An assistant running on the server itself as root can start
`/usr/local/sbin/simai-mcp-session admin` directly.

## Commands

| Command | What it does |
| --- | --- |
| `mcp enable` | Creates the account `simai-mcp` (no password, no shell), the session program `/usr/local/sbin/simai-mcp-session`, its sudo rule and an sshd block for the account. Nobody gets access until a key is added. |
| `mcp key-add --pubkey-file K --owner O` | The key works for owner `O`: only their sites, like the owner in the panel. |
| `mcp key-add --pubkey-file K --admin yes` | The key works for the administrator: the whole server. |
| `mcp key-remove --fingerprint SHA256:...` or `--owner O` | Removes keys; their open sessions end. |
| `mcp status` | Whether MCP is on, its keys (role, fingerprint) and ready lines for clients; `--output json` gives `simai-mcp-status/1`. |
| `mcp disable` | Removes every key, the sudo rule, the session program and the sshd block; open sessions end. |

All of them show a plan first; `--confirm yes` applies. The panel gateway
has `mcp:status`, `mcp:enable`, `mcp:disable`, `mcp:key-add {pubkey, owner |
admin}` and `mcp:key-remove {fingerprint | owner}` for administrators, so
the panel can hand out keys.

## Tools

| Tool | What it does |
| --- | --- |
| `simai_overview` | Who the key is (administrator or an owner) and every command it may use, with `kind` (read or action) and argument patterns. |
| `simai_read {command, args}` | Runs a read: `self:describe`, `site:describe`, `security:status`, `self:alerts`, `logs:nginx`... Refuses actions. |
| `simai_plan {command, args}` | The plan of an action and a `plan_token`. Nothing changes. |
| `simai_confirm {plan_token}` | Runs exactly that plan, once, within 15 minutes, from the same key. Answers `job_id`. |
| `simai_job {job_id, log, cursor}` | The job's state (`running`, `succeeded`, `failed`...) or its output lines after `cursor`. |

Arguments are strings. Answers are the gateway's answers
(`simai-panel-answer/1`); a refusal comes with `isError: true` and a
`reason`: `owner_scope`, `not_allowed`, `invalid_argument`, `owner_blocked`,
`not_a_read_use_plan`, `not_an_action`, `unknown_or_expired_token`,
`token_of_another_account`, `not_over_mcp`.

Files and archives (downloads, deploy archives) do not travel through MCP,
and MCP keys are not managed over MCP: an assistant cannot hand out access.

## Why it is safe

- The role comes from the key, not from the client. Each key line in
  `/etc/ssh/simai-mcp-keys/simai-mcp` (root-owned) has a forced command,
  `sudo -n /usr/local/sbin/simai-mcp-session <role> <key>`, and `restrict`:
  no shell, no forwarding, no terminal; whatever command the client sends is
  ignored.
- Sites run as their owner, so code of a hacked site runs as the owner. That
  account has no sudo rule for MCP and cannot log in as `simai-mcp`: keys of
  that account are only in the root-owned file.
- Every request goes through the panel gateway: the owner's scope, administrator-only
  commands, the blocked owner, validation of each argument. The audit log
  `/var/log/simai-panel-gate.log` names the key: `mcp:acme:<fingerprint>`.
- An action needs two calls: the plan, then the confirmation with its
  one-time token. The token is bound to the key and the exact arguments, so
  a confirmation cannot run anything else. Tell the assistant to show you
  each plan before it confirms; the server's instructions to it say so.
- Server answers may contain text written by site applications (logs, file
  names); the assistant is told to treat it as data.
