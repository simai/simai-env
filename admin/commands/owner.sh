#!/usr/bin/env bash

# Owners: shared accounts that run several sites (like users in hosting
# panels). Sites of one owner can read each other; sites of different owners
# cannot. Owners log in over SSH with keys kept in a root-owned directory, so
# PHP running as the owner cannot add its own key.

SIMAI_OWNERS_GROUP="${SIMAI_OWNERS_GROUP:-simai-owners}"
SIMAI_OWNER_KEYS_DIR="${SIMAI_OWNER_KEYS_DIR:-/etc/ssh/simai-owner-keys}"
SIMAI_OWNER_SSHD_SNIPPET="${SIMAI_OWNER_SSHD_SNIPPET:-/etc/ssh/sshd_config.d/91-simai-owners.conf}"

owner_validate_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
    error "Owner name must be 2-31 characters: a-z, 0-9, '-' and start with a letter"
    return 1
  fi
  case "$name" in
    root|www-data|nobody|admin|simai-admin|"$SIMAI_BASE_USER"|site-*)
      error "Owner name ${name} is reserved"
      return 1
      ;;
  esac
}

owner_write_sshd_snippet() {
  install -d -m 0755 -o root -g root "$SIMAI_OWNER_KEYS_DIR" "$(dirname "$SIMAI_OWNER_SSHD_SNIPPET")" || return 1
  grep -qs 'simai-owners-v1' "$SIMAI_OWNER_SSHD_SNIPPET" && return 0
  cat >"$SIMAI_OWNER_SSHD_SNIPPET" <<EOF
# simai-owners-v1 (managed by simai-env)
Match Group ${SIMAI_OWNERS_GROUP}
    AuthorizedKeysFile ${SIMAI_OWNER_KEYS_DIR}/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    X11Forwarding no
    PermitTunnel no
EOF
  chmod 0644 "$SIMAI_OWNER_SSHD_SNIPPET"
  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t 2>>"$LOG_FILE"; then
      rm -f -- "$SIMAI_OWNER_SSHD_SNIPPET"
      error "sshd rejected the owner configuration; it was removed"
      return 1
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
}

owner_sites() {
  local owner="$1" file
  for file in "$(site_users_registry_dir)"/*; do
    [[ -f "$file" ]] || continue
    [[ "$(head -n1 "$file")" == "$owner" ]] && basename "$file"
  done
  return 0
}

owner_add_key_file() {
  local owner="$1" key_file="$2" keys line added=0
  [[ -f "$key_file" ]] || { error "Public key file not found: ${key_file}"; return 1; }
  keys="${SIMAI_OWNER_KEYS_DIR}/${owner}"
  touch "$keys" && chmod 0644 "$keys" && chown root:root "$keys" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if ! ssh-keygen -l -f /dev/stdin <<<"$line" >/dev/null 2>&1; then
      error "Not a valid SSH public key: ${line:0:40}..."
      return 1
    fi
    grep -qxF "$line" "$keys" || { printf '%s\n' "$line" >>"$keys"; added=$((added + 1)); }
  done <"$key_file"
  info "Keys added for ${owner}: ${added}"
}

owner_create_handler() {
  parse_kv_args "$@"
  local name="${PARSED_ARGS[name]:-}" key_file="${PARSED_ARGS[pubkey-file]:-}"
  require_args "name" || return 1
  owner_validate_name "$name" || return 1
  if id -u "$name" >/dev/null 2>&1 && ! site_is_owner "$name"; then
    error "System user ${name} already exists and is not a simai owner"
    return 1
  fi
  getent group "$SIMAI_OWNERS_GROUP" >/dev/null 2>&1 || groupadd "$SIMAI_OWNERS_GROUP" || return 1
  if ! id -u "$name" >/dev/null 2>&1; then
    useradd --create-home --home-dir "/home/${name}" --shell /bin/bash --user-group \
      --groups "$SIMAI_OWNERS_GROUP" "$name" || { error "Failed to create owner ${name}"; return 1; }
    passwd -l "$name" >/dev/null 2>&1 || true
  fi
  chmod 0750 "/home/${name}"
  # nginx serves the owner's files through the owner's group.
  usermod -a -G "$name" www-data || return 1
  install -d -m 0755 -o root -g root "$(site_owners_registry_dir)" || return 1
  [[ -f "$(site_owners_registry_dir)/${name}" ]] || date -u +%Y-%m-%dT%H:%M:%SZ >"$(site_owners_registry_dir)/${name}"
  owner_write_sshd_snippet || return 1
  touch "${SIMAI_OWNER_KEYS_DIR}/${name}" && chmod 0644 "${SIMAI_OWNER_KEYS_DIR}/${name}"
  [[ -n "$key_file" ]] && { owner_add_key_file "$name" "$key_file" || return 1; }
  site_prepare_isolated_parents
  if nginx -t >>"$LOG_FILE" 2>&1; then
    os_svc_reload nginx >/dev/null 2>&1 || true
  fi
  ui_result_table \
    "Owner|${name}" \
    "Home|/home/${name} (sites linked in ~/sites)" \
    "SSH keys|${SIMAI_OWNER_KEYS_DIR}/${name}" \
    "Password login|disabled"
  ui_next_steps
  ui_kv "Add a site" "simai-admin.sh site add --domain <domain> --owner ${name}"
  ui_kv "Move a site" "simai-admin.sh site isolate --domain <domain> --owner ${name} --confirm yes"
}

owner_add_key_handler() {
  parse_kv_args "$@"
  local name="${PARSED_ARGS[name]:-}" key_file="${PARSED_ARGS[pubkey-file]:-}"
  require_args "name pubkey-file" || return 1
  site_is_owner "$name" || { error "Owner ${name} does not exist"; return 1; }
  owner_write_sshd_snippet || return 1
  owner_add_key_file "$name" "$key_file"
}

owner_list_handler() {
  parse_kv_args "$@"
  local file name rows=()
  for file in "$(site_owners_registry_dir)"/*; do
    [[ -f "$file" ]] || continue
    name=$(basename "$file")
    site_is_owner "$name" || continue
    local sites keys
    sites=$(owner_sites "$name" | paste -sd, -)
    keys=$(grep -cv '^[[:space:]]*$' "${SIMAI_OWNER_KEYS_DIR}/${name}" 2>/dev/null || echo 0)
    rows+=("${name}|keys: ${keys}; projects: ${sites:-none}")
  done
  if [[ ${#rows[@]} -eq 0 ]]; then
    info "No owners yet. Create one: simai-admin.sh owner create --name <name> --pubkey-file <key.pub>"
    return 0
  fi
  ui_result_table "${rows[@]}"
}

owner_remove_handler() {
  parse_kv_args "$@"
  local name="${PARSED_ARGS[name]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  require_args "name" || return 1
  site_is_owner "$name" || { error "Owner ${name} does not exist"; return 1; }
  local sites
  sites=$(owner_sites "$name" | paste -sd, -)
  if [[ -n "$sites" ]]; then
    error "Owner ${name} still runs: ${sites}. Move or remove those sites first."
    return 1
  fi
  if [[ "${confirm,,}" != "yes" ]]; then
    error "Use --confirm yes to remove owner ${name} and its home directory"
    return 1
  fi
  pkill -KILL -u "$name" 2>/dev/null || true
  gpasswd -d www-data "$name" >/dev/null 2>&1 || true
  userdel -r "$name" >/dev/null 2>&1 || userdel "$name" >/dev/null 2>&1 || true
  groupdel "$name" >/dev/null 2>&1 || true
  rm -f -- "${SIMAI_OWNER_KEYS_DIR}/${name}" "$(site_owners_registry_dir)/${name}"
  ui_result_table "Owner|${name}" "Status|removed"
}

register_cmd "owner" "create" "Create an owner account that can run several sites" "owner_create_handler" "name" "pubkey-file=" "tier:advanced"
register_cmd "owner" "add-key" "Allow an SSH public key to log in as an owner" "owner_add_key_handler" "name pubkey-file" "" "tier:advanced"
register_cmd "owner" "list" "List owners, their SSH keys and projects" "owner_list_handler" "" "" "tier:advanced"
register_cmd "owner" "remove" "Remove an owner that has no sites" "owner_remove_handler" "name" "confirm=" "tier:advanced"
