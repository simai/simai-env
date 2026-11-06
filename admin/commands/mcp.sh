#!/usr/bin/env bash

# MCP access (docs/commands/mcp.md): AI assistants (Claude, Codex, Cursor...)
# manage the server through the panel gateway with the same roles, plans and
# audit log as the panel. A client logs in over SSH as the system account
# simai-mcp with a key added here; the key's forced command fixes the role
# (an owner or the administrator), so the client cannot choose it and code
# running as an owner cannot reach it.

SIMAI_MCP_USER="${SIMAI_MCP_USER:-simai-mcp}"
SIMAI_MCP_SESSION="${SIMAI_MCP_SESSION:-/usr/local/sbin/simai-mcp-session}"
SIMAI_MCP_SUDOERS="${SIMAI_MCP_SUDOERS:-/etc/sudoers.d/simai-mcp}"
SIMAI_MCP_KEYS_DIR="${SIMAI_MCP_KEYS_DIR:-/etc/ssh/simai-mcp-keys}"
SIMAI_MCP_SSHD_SNIPPET="${SIMAI_MCP_SSHD_SNIPPET:-/etc/ssh/sshd_config.d/94-simai-mcp.conf}"
SIMAI_MCP_CONFIG="${SIMAI_MCP_CONFIG:-/etc/simai-env/mcp.env}"

mcp_keys_file() { printf '%s/%s' "$SIMAI_MCP_KEYS_DIR" "$SIMAI_MCP_USER"; }

mcp_enabled() { grep -qs '^ENABLED=yes$' "$SIMAI_MCP_CONFIG"; }

mcp_host() {
  local h
  h=$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)
  [[ "$h" == *.* ]] || h=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "${h:-SERVER}"
}

mcp_sshd_ensure() {
  install -d -m 0755 -o root -g root "$SIMAI_MCP_KEYS_DIR" || return 1
  [[ -f "$(mcp_keys_file)" ]] || install -m 0644 -o root -g root /dev/null "$(mcp_keys_file)"
  grep -qs 'simai-mcp-v1' "$SIMAI_MCP_SSHD_SNIPPET" && return 0
  install -d -m 0755 "$(dirname "$SIMAI_MCP_SSHD_SNIPPET")"
  cat >"$SIMAI_MCP_SSHD_SNIPPET" <<EOF
# simai-mcp-v1 (managed by simai-env)
Match User ${SIMAI_MCP_USER}
    AuthorizedKeysFile ${SIMAI_MCP_KEYS_DIR}/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
EOF
  chmod 0644 "$SIMAI_MCP_SSHD_SNIPPET"
  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t 2>>"$LOG_FILE"; then
      rm -f -- "$SIMAI_MCP_SSHD_SNIPPET"
      error "sshd rejected the MCP configuration; it was removed"
      return 1
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
}

mcp_enable_handler() {
  parse_kv_args "$@"
  if [[ "${PARSED_ARGS[confirm]:-}" != "yes" ]]; then
    echo "Plan: let AI assistants manage this server over SSH (MCP), through the panel gateway."
    echo "  - account ${SIMAI_MCP_USER} (no password, no shell: each key runs only the MCP session)"
    echo "  - ${SIMAI_MCP_SESSION}, a sudo rule for it, an sshd block for the account"
    echo "  - nobody gets access until you add a key: mcp key-add --pubkey-file K --owner O|--admin yes"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  command -v python3 >/dev/null || { error "python3 is required for MCP"; return 1; }
  if ! id -u "$SIMAI_MCP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/${SIMAI_MCP_USER}" --shell /bin/sh --user-group "$SIMAI_MCP_USER" || return 1
  fi
  passwd -l "$SIMAI_MCP_USER" >/dev/null 2>&1 || true
  printf '#!/bin/sh\n# simai-env MCP session (role and key come from the forced command)\nexec /usr/bin/python3 -I %s/admin/mcp_server.py "$@"\n' "$SIMAI_ENV_ROOT" >"${SIMAI_MCP_SESSION}.tmp" \
    && chmod 0755 "${SIMAI_MCP_SESSION}.tmp" && mv -f "${SIMAI_MCP_SESSION}.tmp" "$SIMAI_MCP_SESSION" || return 1
  local tmp
  tmp=$(mktemp) || return 1
  printf '# simai-mcp-v1 (managed by simai-env): the MCP account runs the session only; its arguments come from root-owned forced commands.\n%s ALL=(root) NOPASSWD: %s *\n' \
    "$SIMAI_MCP_USER" "$SIMAI_MCP_SESSION" >"$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; error "sudoers rule for MCP rejected by visudo"; return 1; }
  install -m 0440 -o root -g root "$tmp" "$SIMAI_MCP_SUDOERS" && rm -f "$tmp" || return 1
  mcp_sshd_ensure || return 1
  install -d -m 0755 "$(dirname "$SIMAI_MCP_CONFIG")"
  printf 'ENABLED=yes\n' >"$SIMAI_MCP_CONFIG" && chmod 0644 "$SIMAI_MCP_CONFIG"
  ui_result_table "MCP|enabled" "Account|${SIMAI_MCP_USER}" "Keys|$(grep -c 'simai-mcp:' "$(mcp_keys_file)" 2>/dev/null || true)" \
    "Next|mcp key-add --pubkey-file K --owner O (or --admin yes)"
}

mcp_disable_handler() {
  parse_kv_args "$@"
  if [[ "${PARSED_ARGS[confirm]:-}" != "yes" ]]; then
    echo "Plan: turn MCP off: remove every MCP key, the sudo rule, the session program and the sshd block; open sessions end."
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  rm -f -- "$(mcp_keys_file)" "$SIMAI_MCP_SUDOERS" "$SIMAI_MCP_SESSION"
  if [[ -f "$SIMAI_MCP_SSHD_SNIPPET" ]]; then
    rm -f -- "$SIMAI_MCP_SSHD_SNIPPET"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
  [[ -f "$SIMAI_MCP_CONFIG" ]] && printf 'ENABLED=no\n' >"$SIMAI_MCP_CONFIG"
  pkill -f "${SIMAI_ENV_ROOT}/admin/mcp_server.py" >/dev/null 2>&1 || true
  pkill -u "$SIMAI_MCP_USER" >/dev/null 2>&1 || true
  ui_result_table "MCP|disabled"
}

mcp_key_add_handler() {
  parse_kv_args "$@"
  local file="${PARSED_ARGS[pubkey-file]:-}" owner="${PARSED_ARGS[owner]:-}" admin="${PARSED_ARGS[admin]:-}" fp role key line
  require_args "pubkey-file" || return 1
  mcp_enabled || { error "MCP is off: run mcp enable --confirm yes first"; return 1; }
  if [[ -n "$owner" && "$admin" == yes ]] || [[ -z "$owner" && "$admin" != yes ]]; then
    error "Give either --owner NAME (their own sites) or --admin yes (the whole server)"
    return 1
  fi
  if [[ -n "$owner" ]]; then
    site_is_owner "$owner" || { error "Owner ${owner} does not exist"; return 1; }
    role="$owner"
  else
    role="admin"
  fi
  # A plan may come before the key is stored (the panel passes it later).
  fp=$(ssh-keygen -lf "$file" 2>/dev/null | awk '{print $2}' || true)
  if [[ "${PARSED_ARGS[confirm]:-}" != "yes" ]]; then
    if [[ "$role" == admin ]]; then
      echo "Plan: let the key ${fp:-given} manage the whole server through MCP, as the administrator."
    else
      echo "Plan: let the key ${fp:-given} manage the sites of owner ${owner} through MCP."
    fi
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  [[ -f "$file" ]] || { error "Public key file not found: ${file}"; return 1; }
  [[ "$(grep -cv '^\s*$' "$file")" -eq 1 ]] || { error "--pubkey-file must hold exactly one public key"; return 1; }
  [[ "$fp" == SHA256:* ]] || { error "Not a valid SSH public key: ${file}"; return 1; }
  key=$(awk 'NF {print $1" "$2; exit}' "$file")
  if grep -qF " ${key} simai-mcp:" "$(mcp_keys_file)" 2>/dev/null; then
    error "This key is already added; remove it first to change its role"
    return 1
  fi
  mcp_sshd_ensure || return 1
  line=$(printf 'restrict,command="sudo -n %s %s %s" %s simai-mcp:%s:%s' "$SIMAI_MCP_SESSION" "$role" "${fp#SHA256:}" "$key" "$role" "$fp")
  printf '%s\n' "$line" >>"$(mcp_keys_file)"
  ui_result_table "Key|${fp}" "Role|$([[ "$role" == admin ]] && echo administrator || echo "owner ${owner}")" \
    "Connect|ssh -T ${SIMAI_MCP_USER}@$(mcp_host)"
}

mcp_key_remove_handler() {
  parse_kv_args "$@"
  local fp="${PARSED_ARGS[fingerprint]:-}" owner="${PARSED_ARGS[owner]:-}" keys tmp before after
  [[ -n "$fp" || -n "$owner" ]] || { error "Give --fingerprint SHA256:... or --owner NAME"; return 1; }
  [[ -z "$fp" || "$fp" =~ ^SHA256:[A-Za-z0-9+/]{8,64}$ ]] || { error "Fingerprint must look like SHA256:..."; return 1; }
  [[ -z "$owner" || "$owner" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { error "Bad owner name"; return 1; }
  keys=$(mcp_keys_file)
  [[ -f "$keys" ]] || { ui_result_table "Removed|0"; return 0; }
  if [[ "${PARSED_ARGS[confirm]:-}" != "yes" ]]; then
    echo "Plan: remove MCP keys ${fp:+with fingerprint ${fp}}${owner:+of owner ${owner}}; their open sessions end."
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  tmp=$(mktemp) || return 1
  before=$(grep -c ' simai-mcp:' "$keys" || true)
  awk -v fp="$fp" -v owner="$owner" '{
      tag = $NF
      if (fp != "" && substr(tag, length(tag) - length(fp) + 1) == fp) next
      if (owner != "" && index(tag, "simai-mcp:" owner ":") == 1) next
      print
    }' "$keys" >"$tmp"
  install -m 0644 -o root -g root "$tmp" "$keys" && rm -f "$tmp" || return 1
  after=$(grep -c ' simai-mcp:' "$keys" || true)
  # Sessions of removed keys end now: their forced commands carry the key.
  local proc
  for proc in $(pgrep -u root -f "mcp_server.py" 2>/dev/null || true); do
    local cmdline
    cmdline=$(tr '\0' ' ' <"/proc/${proc}/cmdline" 2>/dev/null || true)
    if [[ -n "$fp" && "$cmdline" == *" ${fp#SHA256:}"* ]] || [[ -n "$owner" && "$cmdline" == *"mcp_server.py ${owner} "* ]]; then
      kill "$proc" 2>/dev/null || true
    fi
  done
  ui_result_table "Removed|$((before - after))" "Left|${after}"
}

mcp_status_handler() {
  parse_kv_args "$@"
  python3 -I - "$(mcp_keys_file)" "$SIMAI_MCP_CONFIG" "$SIMAI_MCP_USER" "$(mcp_host)" "${SIMAI_COMMAND_OUTPUT:-human}" <<'PY'
import json, os, sys
keys_file, config, user, host, output = sys.argv[1:6]
enabled = False
try:
    enabled = "ENABLED=yes" in open(config).read().split()
except OSError:
    pass
keys = []
try:
    for line in open(keys_file):
        tag = line.split()[-1] if line.strip() else ""
        if tag.startswith("simai-mcp:"):
            _, role, fp = tag.split(":", 2)
            keys.append({"role": "administrator" if role == "admin" else "owner",
                         "owner": None if role == "admin" else role, "fingerprint": fp})
except OSError:
    pass
connect = f"ssh -T {user}@{host}"
data = {"schema": "simai-mcp-status/1", "enabled": enabled, "account": user, "keys": keys,
        "connect": connect,
        "clients": {
            "claude_code": f"claude mcp add simai -- ssh -T {user}@{host}",
            "codex": f"codex mcp add simai -- ssh -T {user}@{host}",
            "json": {"mcpServers": {"simai": {"command": "ssh", "args": ["-T", f"{user}@{host}"]}}}}}
if output == "json":
    print(json.dumps(data))
else:
    print(f"MCP: {'enabled' if enabled else 'disabled'}; keys: {len(keys)}")
    for k in keys:
        print(f"  {k['fingerprint']}  {k['role']}{' ' + k['owner'] if k['owner'] else ''}")
    if enabled:
        print(f"Connect: {connect}")
        print(f"  Claude Code: {data['clients']['claude_code']}")
        print(f"  Codex:       {data['clients']['codex']}")
        print(f"  JSON config: {json.dumps(data['clients']['json'])}")
PY
}

register_cmd "mcp" "enable" "Let AI assistants manage this server over SSH (MCP), through the panel gateway" "mcp_enable_handler" "" "confirm=" "tier:advanced plan:handler"
register_cmd "mcp" "disable" "Turn MCP off: remove its keys, sudo rule and sshd block" "mcp_disable_handler" "" "confirm=" "tier:advanced plan:handler"
register_cmd "mcp" "key-add" "Allow an SSH key to use MCP as an owner (their sites) or as the administrator" "mcp_key_add_handler" "pubkey-file" "owner= admin= confirm=" "tier:advanced plan:handler"
register_cmd "mcp" "key-remove" "Remove MCP keys by fingerprint or owner" "mcp_key_remove_handler" "" "fingerprint= owner= confirm=" "tier:advanced plan:handler"
register_cmd "mcp" "status" "Show MCP access, its keys and how to connect AI clients" "mcp_status_handler" "" "" "effects:read"
