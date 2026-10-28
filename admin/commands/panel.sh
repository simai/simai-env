#!/usr/bin/env bash

# Panel gateway for SIMAI ENV Panel (docs/architecture/panel-gate.md). The
# panel's account simai-panel may run exactly one program as root, the
# gateway (admin/panel_gate.py), which reads one JSON request on stdin. An
# optional SSH key gives a panel on another machine the same single entry.

SIMAI_PANEL_USER="${SIMAI_PANEL_USER:-simai-panel}"
SIMAI_PANEL_GATE="${SIMAI_PANEL_GATE:-/usr/local/sbin/simai-panel-gate}"
SIMAI_PANEL_SUDOERS="${SIMAI_PANEL_SUDOERS:-/etc/sudoers.d/simai-panel}"
SIMAI_PANEL_KEYS_DIR="${SIMAI_PANEL_KEYS_DIR:-/etc/ssh/simai-panel-keys}"
SIMAI_PANEL_SSHD_SNIPPET="${SIMAI_PANEL_SSHD_SNIPPET:-/etc/ssh/sshd_config.d/93-simai-panel.conf}"
SIMAI_PANEL_GATE_LOG="${SIMAI_PANEL_GATE_LOG:-/var/log/simai-panel-gate.log}"

panel_gate_ssh_ensure() {
  install -d -m 0755 -o root -g root "$SIMAI_PANEL_KEYS_DIR" || return 1
  local keys="${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}"
  [[ -f "$keys" ]] || install -m 0644 -o root -g root /dev/null "$keys"
  grep -qs 'simai-panel-v1' "$SIMAI_PANEL_SSHD_SNIPPET" && return 0
  install -d -m 0755 "$(dirname "$SIMAI_PANEL_SSHD_SNIPPET")"
  cat >"$SIMAI_PANEL_SSHD_SNIPPET" <<EOF
# simai-panel-v1 (managed by simai-env)
Match User ${SIMAI_PANEL_USER}
    AuthorizedKeysFile ${SIMAI_PANEL_KEYS_DIR}/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
EOF
  chmod 0644 "$SIMAI_PANEL_SSHD_SNIPPET"
  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t 2>>"$LOG_FILE"; then
      rm -f -- "$SIMAI_PANEL_SSHD_SNIPPET"
      error "sshd rejected the panel key configuration; it was removed"
      return 1
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
}

panel_gate_enable_handler() {
  parse_kv_args "$@"
  local pubkey_file="${PARSED_ARGS[pubkey-file]:-}" fp=""
  if [[ -n "$pubkey_file" ]]; then
    [[ -f "$pubkey_file" ]] || { error "Public key file not found: ${pubkey_file}"; return 1; }
    [[ "$(grep -cv '^\s*$' "$pubkey_file")" -eq 1 ]] || { error "--pubkey-file must hold exactly one public key"; return 1; }
    fp=$(ssh-keygen -lf "$pubkey_file" 2>/dev/null | awk '{print $2}')
    [[ -n "$fp" ]] || { error "Not a valid SSH public key: ${pubkey_file}"; return 1; }
  fi
  command -v python3 >/dev/null || { error "python3 is required for the panel gateway"; return 1; }
  if ! id -u "$SIMAI_PANEL_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/${SIMAI_PANEL_USER}" --shell /bin/sh --user-group "$SIMAI_PANEL_USER" || return 1
  fi
  passwd -l "$SIMAI_PANEL_USER" >/dev/null 2>&1 || true
  # No arguments reach the gateway: the request comes on stdin only.
  printf '#!/bin/sh\n# simai-env panel gateway\nexec /usr/bin/python3 -I %s/admin/panel_gate.py\n' "$SIMAI_ENV_ROOT" >"${SIMAI_PANEL_GATE}.tmp" \
    && chmod 0755 "${SIMAI_PANEL_GATE}.tmp" && mv -f "${SIMAI_PANEL_GATE}.tmp" "$SIMAI_PANEL_GATE" || return 1
  local tmp
  tmp=$(mktemp) || return 1
  printf '# simai-panel-v1 (managed by simai-env): the panel may run the gateway only, without arguments.\n%s ALL=(root) NOPASSWD: %s ""\n' "$SIMAI_PANEL_USER" "$SIMAI_PANEL_GATE" >"$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; error "sudoers rule for ${SIMAI_PANEL_USER} rejected by visudo"; return 1; }
  install -m 0440 -o root -g root "$tmp" "$SIMAI_PANEL_SUDOERS" && rm -f "$tmp" || return 1
  [[ -f "$SIMAI_PANEL_GATE_LOG" ]] || install -m 0600 -o root -g root /dev/null "$SIMAI_PANEL_GATE_LOG"
  if [[ -n "$pubkey_file" ]]; then
    panel_gate_ssh_ensure || return 1
    local keys="${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}" key
    key=$(awk 'NF {print $1" "$2; exit}' "$pubkey_file")
    if ! grep -qF " simai-panel:${fp}" "$keys"; then
      printf 'restrict,command="sudo -n %s" %s simai-panel:%s\n' "$SIMAI_PANEL_GATE" "$key" "$fp" >>"$keys"
    fi
  fi
  local -a rows=("Account|${SIMAI_PANEL_USER}" "Gateway|${SIMAI_PANEL_GATE}" "Call|sudo -n ${SIMAI_PANEL_GATE} < request.json")
  [[ -n "$fp" ]] && rows+=("SSH key|${fp}")
  ui_result_table "${rows[@]}"
}

panel_gate_disable_handler() {
  rm -f -- "$SIMAI_PANEL_SUDOERS" "$SIMAI_PANEL_GATE" "${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}"
  if [[ -f "$SIMAI_PANEL_SSHD_SNIPPET" ]]; then
    rm -f -- "$SIMAI_PANEL_SSHD_SNIPPET"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
  ui_result_table "Gateway|disabled" "Log kept|${SIMAI_PANEL_GATE_LOG}"
}

panel_gate_status_handler() {
  local enabled=no keys=0
  [[ -x "$SIMAI_PANEL_GATE" && -f "$SIMAI_PANEL_SUDOERS" ]] && enabled=yes
  [[ -f "${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}" ]] && keys=$(grep -c ' simai-panel:' "${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}" || true)
  ui_result_table "Enabled|${enabled}" "Account|${SIMAI_PANEL_USER}" "SSH keys|${keys}" "Log|${SIMAI_PANEL_GATE_LOG}"
}

register_cmd "panel" "gate-enable" "Let the panel account call the read-only gateway (optionally over SSH)" "panel_gate_enable_handler" "" "pubkey-file=" "tier:advanced"
register_cmd "panel" "gate-disable" "Remove the panel gateway, its sudo rule and SSH keys" "panel_gate_disable_handler" "" "" "tier:advanced"
register_cmd "panel" "gate-status" "Show whether the panel gateway is enabled" "panel_gate_status_handler" "" "" "effects:read"
