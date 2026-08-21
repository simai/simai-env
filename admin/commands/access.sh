#!/usr/bin/env bash

access_print_list() {
  local -a logins=("$@")
  local login type scope enabled auth_mode
  local w_login=5 w_type=4 w_scope=5 w_enabled=7 w_auth=4
  for login in "${logins[@]}"; do
    access_load_metadata "$login" || continue
    type="${ACCESS_META[TYPE]:-}"
    scope="${ACCESS_META[SCOPE]:-}"
    enabled="${ACCESS_META[ENABLED]:-}"
    auth_mode="${ACCESS_META[AUTH_MODE]:-}"
    [[ ${#login} -gt $w_login ]] && w_login=${#login}
    [[ ${#type} -gt $w_type ]] && w_type=${#type}
    [[ ${#scope} -gt $w_scope ]] && w_scope=${#scope}
    [[ ${#enabled} -gt $w_enabled ]] && w_enabled=${#enabled}
    [[ ${#auth_mode} -gt $w_auth ]] && w_auth=${#auth_mode}
  done
  local sep
  sep="+$(printf '%*s' "$((w_login+2))" "" | tr ' ' '-')+$(printf '%*s' "$((w_type+2))" "" | tr ' ' '-')+$(printf '%*s' "$((w_scope+2))" "" | tr ' ' '-')+$(printf '%*s' "$((w_enabled+2))" "" | tr ' ' '-')+$(printf '%*s' "$((w_auth+2))" "" | tr ' ' '-')+"
  printf "%s\n" "$sep"
  printf "| %-*s | %-*s | %-*s | %-*s | %-*s |\n" "$w_login" "Login" "$w_type" "Type" "$w_scope" "Scope" "$w_enabled" "Enabled" "$w_auth" "Auth"
  printf "%s\n" "$sep"
  for login in "${logins[@]}"; do
    access_load_metadata "$login" || continue
    printf "| %-*s | %-*s | %-*s | %-*s | %-*s |\n" \
      "$w_login" "$login" \
      "$w_type" "${ACCESS_META[TYPE]:-}" \
      "$w_scope" "${ACCESS_META[SCOPE]:-}" \
      "$w_enabled" "${ACCESS_META[ENABLED]:-}" \
      "$w_auth" "${ACCESS_META[AUTH_MODE]:-}"
  done
  printf "%s\n" "$sep"
}

access_list_handler() {
  parse_kv_args "$@"
  local scope="${PARSED_ARGS[scope]:-}"
  local domain="${PARSED_ARGS[domain]:-}"
  local -a logins=() filtered=()
  mapfile -t logins < <(access_list_logins)
  if [[ ${#logins[@]} -eq 0 ]]; then
    ui_result_info "No access entries found."
    return 0
  fi
  if [[ -n "$scope" ]]; then
    local login
    for login in "${logins[@]}"; do
      access_load_metadata "$login" || continue
      [[ "${ACCESS_META[SCOPE]:-}" == "$scope" ]] && filtered+=("$login")
    done
    logins=("${filtered[@]}")
  fi
  if [[ -n "$domain" ]]; then
    local login
    filtered=()
    for login in "${logins[@]}"; do
      access_load_metadata "$login" || continue
      [[ "${ACCESS_META[DOMAIN]:-}" == "$domain" ]] && filtered+=("$login")
    done
    logins=("${filtered[@]}")
  fi
  if [[ ${#logins[@]} -eq 0 ]]; then
    if [[ -n "$scope" ]]; then
      ui_result_info "No access entries found for scope ${scope}."
    elif [[ -n "$domain" ]]; then
      ui_result_info "No access entries found for domain ${domain}."
    else
      ui_result_info "No access entries found."
    fi
    return 0
  fi
  access_print_list "${logins[@]}"
}

access_show_handler() {
  parse_kv_args "$@"
  local login="${PARSED_ARGS[login]:-}"
  login=$(access_pick_login "$login") || return $?
  access_load_metadata "$login" || { error "Access login ${login} not found"; return 1; }
  ui_result_table \
    "Login|${login}" \
    "Type|${ACCESS_META[TYPE]:-}" \
    "Scope|${ACCESS_META[SCOPE]:-}" \
    "Domain|${ACCESS_META[DOMAIN]:--}" \
    "Root path|${ACCESS_META[ROOT_PATH]:-}" \
    "Home path|${ACCESS_META[HOME_PATH]:-}" \
    "Chroot|${ACCESS_META[JAIL_PATH]:-}" \
    "Mount unit|${ACCESS_META[MOUNT_UNIT]:-}" \
    "Enabled|${ACCESS_META[ENABLED]:-}" \
    "Auth mode|${ACCESS_META[AUTH_MODE]:-}" \
    "Created at|${ACCESS_META[CREATED_AT]:-}" \
    "Updated at|${ACCESS_META[UPDATED_AT]:-}"
  ui_next_steps \
    "Disable: simai-admin.sh access disable --login ${login}" \
    "Reset password: simai-admin.sh access reset-password --login ${login}"
}

access_doctor_add_result() {
  local status="$1" check="$2" detail="$3"
  ACCESS_DOCTOR_ROWS+=("${status}|${check}|${detail}")
}

access_doctor_print() {
  local row status check detail
  local pass=0 warn=0 fail=0
  for row in "${ACCESS_DOCTOR_ROWS[@]}"; do
    status="${row%%|*}"
    case "$status" in
      PASS) pass=$((pass + 1)) ;;
      WARN) warn=$((warn + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
    esac
  done
  ui_section "Summary"
  print_kv_table "PASS|${pass}" "WARN|${warn}" "FAIL|${fail}"
  ui_section "Checks"
  for row in "${ACCESS_DOCTOR_ROWS[@]}"; do
    status="${row%%|*}"
    detail="${row#*|}"
    check="${detail%%|*}"
    detail="${detail#*|}"
    printf '[%s] %s — %s\n' "$status" "$check" "$detail"
  done
  [[ "$fail" -eq 0 ]]
}

access_doctor_handler() {
  parse_kv_args "$@"
  ui_header "SIMAI ENV · Access doctor"
  local strict="${PARSED_ARGS[strict]:-no}"
  ACCESS_DOCTOR_ROWS=()

  if [[ -f "$SIMAI_ACCESS_SSHD_SNIPPET" ]]; then
    access_doctor_add_result "PASS" "sshd snippet" "$SIMAI_ACCESS_SSHD_SNIPPET"
    if grep -q "ForceCommand internal-sftp" "$SIMAI_ACCESS_SSHD_SNIPPET" &&
      grep -q "AllowTcpForwarding no" "$SIMAI_ACCESS_SSHD_SNIPPET" &&
      grep -q "X11Forwarding no" "$SIMAI_ACCESS_SSHD_SNIPPET" &&
      grep -q "PermitTTY no" "$SIMAI_ACCESS_SSHD_SNIPPET"; then
      access_doctor_add_result "PASS" "SFTP restriction" "ForceCommand internal-sftp with forwarding disabled"
    else
      access_doctor_add_result "FAIL" "SFTP restriction" "Missing internal-sftp or forwarding restrictions in sshd snippet"
    fi
    if grep -q "ChrootDirectory ${SIMAI_ACCESS_JAIL_BASE}/%u" "$SIMAI_ACCESS_SSHD_SNIPPET"; then
      access_doctor_add_result "PASS" "Project chroot rule" "ChrootDirectory uses managed jail base"
    else
      access_doctor_add_result "FAIL" "Project chroot rule" "Missing managed ChrootDirectory rule"
    fi
  else
    access_doctor_add_result "WARN" "sshd snippet" "Missing ${SIMAI_ACCESS_SSHD_SNIPPET}; no managed access users may exist"
  fi
  if sshd -t >/dev/null 2>&1; then
    access_doctor_add_result "PASS" "sshd syntax" "OK"
  else
    access_doctor_add_result "FAIL" "sshd syntax" "sshd -t failed"
  fi

  local metadata_dir
  metadata_dir=$(access_dir)
  if [[ -d "$metadata_dir" ]]; then
    local meta_mode meta_owner
    meta_mode=$(stat -c "%a" "$metadata_dir" 2>/dev/null || echo "")
    meta_owner=$(stat -c "%U:%G" "$metadata_dir" 2>/dev/null || echo "")
    if [[ "$meta_owner" == "root:root" && "$meta_mode" =~ ^7[05]0$|^755$ ]]; then
      access_doctor_add_result "PASS" "metadata dir" "${meta_owner} ${meta_mode}"
    else
      access_doctor_add_result "WARN" "metadata dir" "${meta_owner:-unknown} ${meta_mode:-unknown}"
    fi
  else
    access_doctor_add_result "PASS" "metadata dir" "No metadata directory yet"
  fi

  local -a logins=()
  mapfile -t logins < <(access_list_logins 2>/dev/null || true)
  if [[ ${#logins[@]} -eq 0 ]]; then
    access_doctor_add_result "PASS" "managed users" "No access entries found"
  fi

  local login file mode owner type enabled shell jail site_dir root
  for login in "${logins[@]}"; do
    file=$(access_metadata_file "$login")
    mode=$(stat -c "%a" "$file" 2>/dev/null || echo "")
    owner=$(stat -c "%U:%G" "$file" 2>/dev/null || echo "")
    if [[ "$owner" == "root:root" && "$mode" == "640" ]]; then
      access_doctor_add_result "PASS" "${login}: metadata" "${owner} ${mode}"
    else
      access_doctor_add_result "FAIL" "${login}: metadata" "${owner:-unknown} ${mode:-unknown}; expected root:root 640"
    fi
    access_load_metadata "$login" || {
      access_doctor_add_result "FAIL" "${login}: metadata load" "failed"
      continue
    }
    type="${ACCESS_META[TYPE]:-}"
    enabled="${ACCESS_META[ENABLED]:-}"
    if id -u "$login" >/dev/null 2>&1; then
      shell=$(getent passwd "$login" | awk -F: '{print $7}')
      if [[ "$shell" == "/usr/sbin/nologin" || "$shell" == "/sbin/nologin" ]]; then
        access_doctor_add_result "PASS" "${login}: shell" "$shell"
      else
        access_doctor_add_result "FAIL" "${login}: shell" "$shell; expected nologin"
      fi
    elif [[ "$enabled" == "no" ]]; then
      access_doctor_add_result "WARN" "${login}: user" "system user missing for disabled access"
    else
      access_doctor_add_result "FAIL" "${login}: user" "system user missing"
    fi
    if [[ "$type" == "project" ]]; then
      jail="${ACCESS_META[JAIL_PATH]:-$(access_project_jail_root "$login")}"
      site_dir=$(access_project_site_dir "$login")
      root="${ACCESS_META[ROOT_PATH]:-}"
      if [[ -d "$jail" ]]; then
        mode=$(stat -c "%a" "$jail" 2>/dev/null || echo "")
        owner=$(stat -c "%U:%G" "$jail" 2>/dev/null || echo "")
        if [[ "$owner" == "root:root" && "$mode" == "755" ]]; then
          access_doctor_add_result "PASS" "${login}: chroot" "${owner} ${mode}"
        else
          access_doctor_add_result "FAIL" "${login}: chroot" "${owner:-unknown} ${mode:-unknown}; expected root:root 755"
        fi
      else
        access_doctor_add_result "FAIL" "${login}: chroot" "missing ${jail}"
      fi
      if [[ -n "$root" && -d "$root" ]]; then
        access_doctor_add_result "PASS" "${login}: project root" "$root"
      else
        access_doctor_add_result "FAIL" "${login}: project root" "missing ${root:-<empty>}"
      fi
      if [[ "$enabled" == "yes" ]]; then
        if access_mount_is_active "$site_dir"; then
          access_doctor_add_result "PASS" "${login}: bind mount" "$site_dir"
        else
          access_doctor_add_result "WARN" "${login}: bind mount" "not active at ${site_dir}"
        fi
      fi
    fi
  done

  access_doctor_print
  local rc=$?
  if [[ "${strict,,}" == "yes" ]]; then
    return "$rc"
  fi
  return 0
}

access_create_global_handler() {
  parse_kv_args "$@"
  local login="${PARSED_ARGS[login]:-}"
  local password="${PARSED_ARGS[password]:-}"
  if [[ -z "$login" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    login=$(prompt "login")
    [[ -z "$login" ]] && command_cancelled && return $?
  fi
  require_args "login" || return 1
  access_validate_login "$login" || return 1
  access_ensure_prereqs || return 1
  ensure_user || return 1
  if access_exists "$login"; then
    error "Access login ${login} already exists"
    return 1
  fi
  if id -u "$login" >/dev/null 2>&1; then
    error "System user ${login} already exists; refusing to attach managed access metadata"
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local create_choice
    create_choice=$(select_from_list "Create global file access ${login}?" "no" "no" "yes")
    [[ "$create_choice" == "yes" ]] || { command_cancelled; return $?; }
  fi
  [[ -z "$password" ]] && password="$(access_generate_password)"
  access_ensure_global_group || return 1
  access_write_sshd_snippet || return 1
  local home
  home=$(access_global_home "$login")
  access_create_system_user "$login" "$home" "$SIMAI_ACCESS_GROUP_GLOBAL" || return 1
  access_ensure_global_home "$login" "$SIMAI_ACCESS_GROUP_GLOBAL" || return 1
  access_set_password "$login" "$password" || return 1
  access_grant_global_acl "$login" || return 1
  local now
  now=$(date +"%Y-%m-%dT%H:%M:%S")
  access_write_metadata "$login" \
    "TYPE|global" \
    "SCOPE|all-projects" \
    "DOMAIN|" \
    "ROOT_PATH|${WWW_ROOT}" \
    "HOME_PATH|${home}" \
    "ENABLED|yes" \
    "AUTH_MODE|password" \
    "CREATED_AT|${now}" \
    "UPDATED_AT|${now}"
  ui_result_table \
    "Login|${login}" \
    "Type|global" \
    "Root path|${WWW_ROOT}" \
    "Home path|${home}" \
    "Auth mode|password" \
    "Password|${password}" \
    "SSHD mode|internal-sftp"
  ui_next_steps \
    "Connect: sftp ${login}@<server>" \
    "Show details: simai-admin.sh access show --login ${login}" \
    "Reset password later: simai-admin.sh access reset-password --login ${login}"
}

access_create_project_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local login="${PARSED_ARGS[login]:-}"
  local password="${PARSED_ARGS[password]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 0
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
    [[ -z "$domain" ]] && command_cancelled && return $?
  fi
  if [[ -z "$login" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    login=$(prompt "login")
    [[ -z "$login" ]] && command_cancelled && return $?
  fi
  require_args "domain login" || return 1
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1
  access_validate_login "$login" || return 1
  access_ensure_prereqs || return 1
  ensure_user || return 1
  if access_exists "$login"; then
    error "Access login ${login} already exists"
    return 1
  fi
  if id -u "$login" >/dev/null 2>&1; then
    error "System user ${login} already exists; refusing to attach managed access metadata"
    return 1
  fi
  read_site_metadata "$domain"
  local root="${SITE_META[root]:-${WWW_ROOT}/${domain}}"
  if [[ "$root" != "${WWW_ROOT}/"* ]]; then
    error "Project root ${root} is not under ${WWW_ROOT}; project access requires standard root layout."
    return 1
  fi
  if [[ ! -d "$root" ]]; then
    error "Project root ${root} does not exist"
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local create_choice
    create_choice=$(select_from_list "Create project file access ${login} for ${domain}?" "no" "no" "yes")
    [[ "$create_choice" == "yes" ]] || { command_cancelled; return $?; }
  fi
  [[ -z "$password" ]] && password="$(access_generate_password)"
  access_ensure_project_group || return 1
  access_write_sshd_snippet || return 1
  local jail_root
  jail_root=$(access_project_jail_root "$login")
  access_create_system_user "$login" "$jail_root" "$SIMAI_ACCESS_GROUP_PROJECT" || return 1
  access_set_password "$login" "$password" || return 1
  access_grant_project_acl "$login" "$root" || return 1
  access_mount_project_root "$login" "$root" || return 1
  local site_dir mount_unit
  site_dir=$(access_project_site_dir "$login")
  mount_unit=$(access_mount_unit_name "$site_dir")
  local now
  now=$(date +"%Y-%m-%dT%H:%M:%S")
  access_write_metadata "$login" \
    "TYPE|project" \
    "SCOPE|site" \
    "DOMAIN|${domain}" \
    "ROOT_PATH|${root}" \
    "JAIL_PATH|${jail_root}" \
    "MOUNT_UNIT|${mount_unit}" \
    "ENABLED|yes" \
    "AUTH_MODE|password" \
    "CREATED_AT|${now}" \
    "UPDATED_AT|${now}"
  ui_result_table \
    "Login|${login}" \
    "Type|project" \
    "Domain|${domain}" \
    "Root path|${root}" \
    "Chroot|${jail_root}" \
    "SFTP path|/site" \
    "Auth mode|password" \
    "Password|${password}" \
    "SSHD mode|internal-sftp (chroot)"
  ui_next_steps \
    "Connect: sftp ${login}@<server>" \
    "Navigate: cd /site" \
    "Show details: simai-admin.sh access show --login ${login}"
}

access_disable_handler() {
  parse_kv_args "$@"
  local login="${PARSED_ARGS[login]:-}"
  login=$(access_pick_login "$login") || return $?
  access_load_metadata "$login" || { error "Access login ${login} not found"; return 1; }
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Disable access ${login}?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || { command_cancelled; return $?; }
  fi
  if [[ "${ACCESS_META[TYPE]:-}" == "project" ]]; then
    access_disable_mount_unit "$login" || true
  fi
  usermod -L "$login"
  local now
  now=$(date +"%Y-%m-%dT%H:%M:%S")
  access_write_metadata "$login" \
    "TYPE|${ACCESS_META[TYPE]:-}" \
    "SCOPE|${ACCESS_META[SCOPE]:-}" \
    "DOMAIN|${ACCESS_META[DOMAIN]:-}" \
    "ROOT_PATH|${ACCESS_META[ROOT_PATH]:-}" \
    "HOME_PATH|${ACCESS_META[HOME_PATH]:-}" \
    "JAIL_PATH|${ACCESS_META[JAIL_PATH]:-}" \
    "MOUNT_UNIT|${ACCESS_META[MOUNT_UNIT]:-}" \
    "ENABLED|no" \
    "AUTH_MODE|${ACCESS_META[AUTH_MODE]:-password}" \
    "CREATED_AT|${ACCESS_META[CREATED_AT]:-}" \
    "UPDATED_AT|${now}"
  ui_result_table "Login|${login}" "Status|disabled"
}

access_enable_handler() {
  parse_kv_args "$@"
  local login="${PARSED_ARGS[login]:-}"
  login=$(access_pick_login "$login") || return $?
  access_load_metadata "$login" || { error "Access login ${login} not found"; return 1; }
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Enable access ${login}?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || { command_cancelled; return $?; }
  fi
  if [[ "${ACCESS_META[TYPE]:-}" == "project" ]]; then
    local root="${ACCESS_META[ROOT_PATH]:-}"
    local jail="${ACCESS_META[JAIL_PATH]:-$(access_project_jail_root "$login")}"
    if [[ -n "$root" && -d "$root" ]]; then
      access_mount_project_root "$login" "$root" || return 1
    else
      error "Project root missing for ${login}; cannot re-enable access."
      return 1
    fi
    if [[ -n "$jail" && -d "$jail" ]]; then
      :
    else
      error "Chroot directory missing for ${login}; cannot re-enable access."
      return 1
    fi
  fi
  usermod -U "$login"
  local now
  now=$(date +"%Y-%m-%dT%H:%M:%S")
  access_write_metadata "$login" \
    "TYPE|${ACCESS_META[TYPE]:-}" \
    "SCOPE|${ACCESS_META[SCOPE]:-}" \
    "DOMAIN|${ACCESS_META[DOMAIN]:-}" \
    "ROOT_PATH|${ACCESS_META[ROOT_PATH]:-}" \
    "HOME_PATH|${ACCESS_META[HOME_PATH]:-}" \
    "JAIL_PATH|${ACCESS_META[JAIL_PATH]:-}" \
    "MOUNT_UNIT|${ACCESS_META[MOUNT_UNIT]:-}" \
    "ENABLED|yes" \
    "AUTH_MODE|${ACCESS_META[AUTH_MODE]:-password}" \
    "CREATED_AT|${ACCESS_META[CREATED_AT]:-}" \
    "UPDATED_AT|${now}"
  ui_result_table "Login|${login}" "Status|enabled"
}

access_reset_password_handler() {
  parse_kv_args "$@"
  local login="${PARSED_ARGS[login]:-}"
  local password="${PARSED_ARGS[password]:-}"
  login=$(access_pick_login "$login") || return $?
  access_load_metadata "$login" || { error "Access login ${login} not found"; return 1; }
  [[ -z "$password" ]] && password="$(access_generate_password)"
  access_set_password "$login" "$password" || return 1
  local now
  now=$(date +"%Y-%m-%dT%H:%M:%S")
  access_write_metadata "$login" \
    "TYPE|${ACCESS_META[TYPE]:-}" \
    "SCOPE|${ACCESS_META[SCOPE]:-}" \
    "DOMAIN|${ACCESS_META[DOMAIN]:-}" \
    "ROOT_PATH|${ACCESS_META[ROOT_PATH]:-}" \
    "HOME_PATH|${ACCESS_META[HOME_PATH]:-}" \
    "JAIL_PATH|${ACCESS_META[JAIL_PATH]:-}" \
    "MOUNT_UNIT|${ACCESS_META[MOUNT_UNIT]:-}" \
    "ENABLED|${ACCESS_META[ENABLED]:-yes}" \
    "AUTH_MODE|${ACCESS_META[AUTH_MODE]:-password}" \
    "CREATED_AT|${ACCESS_META[CREATED_AT]:-}" \
    "UPDATED_AT|${now}"
  ui_result_table \
    "Login|${login}" \
    "Status|password reset" \
    "Password|${password}"
}

access_remove_handler() {
  parse_kv_args "$@"
  local login="${PARSED_ARGS[login]:-}"
  login=$(access_pick_login "$login") || return $?
  access_load_metadata "$login" || { error "Access login ${login} not found"; return 1; }
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Remove access ${login} and delete its user?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || { command_cancelled; return $?; }
  fi
  if [[ "${ACCESS_META[TYPE]:-}" == "project" ]]; then
    access_disable_mount_unit "$login" || true
    access_unmount_project_root "$login" || true
  fi
  if id -u "$login" >/dev/null 2>&1; then
    userdel "$login" 2>/dev/null || userdel -r "$login" 2>/dev/null || true
  fi
  if [[ "${ACCESS_META[TYPE]:-}" == "project" ]]; then
    local jail_root
    jail_root="${ACCESS_META[JAIL_PATH]:-$(access_project_jail_root "$login")}"
    access_safe_remove_dir "$SIMAI_ACCESS_JAIL_BASE" "$jail_root" || true
  fi
  if [[ "${ACCESS_META[TYPE]:-}" == "global" ]]; then
    local home
    home="${ACCESS_META[HOME_PATH]:-}"
    if [[ -z "$home" ]]; then
      home=$(access_global_home "$login")
    fi
    access_safe_remove_dir "$SIMAI_ACCESS_HOME_BASE" "$home" || true
  fi
  rm -f "$(access_metadata_file "$login")"
  ui_result_table "Login|${login}" "Status|removed"
}

access_add_key_handler() {
  parse_kv_args "$@"
  local login="${PARSED_ARGS[login]:-}"
  local key_file="${PARSED_ARGS[pubkey-file]:-}"
  login=$(access_pick_login "$login") || return $?
  if [[ -z "$key_file" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    key_file=$(prompt "public key file")
    [[ -z "$key_file" ]] && command_cancelled && return $?
  fi
  require_args "login pubkey-file" || return 1
  if [[ ! -f "$key_file" ]]; then
    error "Public key file not found: ${key_file}"
    return 1
  fi
  local pubkey
  pubkey=$(grep -E '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) ' "$key_file" | head -n 1)
  if [[ -z "$pubkey" ]]; then
    error "No valid SSH public key found in ${key_file}"
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Add this SSH key to access ${login}?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || { command_cancelled; return $?; }
  fi
  access_install_pubkey "$login" "$pubkey" || return 1
  access_load_metadata "$login" || { error "Access login ${login} not found"; return 1; }
  local now auth_mode
  now=$(date +"%Y-%m-%dT%H:%M:%S")
  auth_mode="${ACCESS_META[AUTH_MODE]:-password}"
  if [[ "$auth_mode" == "password" ]]; then
    auth_mode="password+key"
  elif [[ "$auth_mode" == "key" ]]; then
    auth_mode="key"
  elif [[ "$auth_mode" != *"key"* ]]; then
    auth_mode="${auth_mode}+key"
  fi
  access_write_metadata "$login" \
    "TYPE|${ACCESS_META[TYPE]:-}" \
    "SCOPE|${ACCESS_META[SCOPE]:-}" \
    "DOMAIN|${ACCESS_META[DOMAIN]:-}" \
    "ROOT_PATH|${ACCESS_META[ROOT_PATH]:-}" \
    "JAIL_PATH|${ACCESS_META[JAIL_PATH]:-}" \
    "HOME_PATH|${ACCESS_META[HOME_PATH]:-}" \
    "MOUNT_UNIT|${ACCESS_META[MOUNT_UNIT]:-}" \
    "ENABLED|${ACCESS_META[ENABLED]:-yes}" \
    "AUTH_MODE|${auth_mode}" \
    "CREATED_AT|${ACCESS_META[CREATED_AT]:-}" \
    "UPDATED_AT|${now}"
  ui_result_table \
    "Login|${login}" \
    "Status|SSH key added" \
    "Auth mode|${auth_mode}"
}

register_cmd "access" "list" "List managed file accesses" "access_list_handler" "" "scope= domain=" ""
register_cmd "access" "show" "Show access details" "access_show_handler" "login" "" ""
register_cmd "access" "doctor" "Check managed access security baseline" "access_doctor_handler" "" "strict=no" ""
register_cmd "access" "create-global" "Create global SFTP access" "access_create_global_handler" "login" "password=" "menu:internal-confirm"
register_cmd "access" "create-project" "Create project SFTP access" "access_create_project_handler" "domain login" "password=" "menu:internal-confirm"
register_cmd "access" "disable" "Disable access" "access_disable_handler" "login" "" "menu:internal-confirm"
register_cmd "access" "enable" "Enable access" "access_enable_handler" "login" "" "menu:internal-confirm"
register_cmd "access" "reset-password" "Reset access password" "access_reset_password_handler" "login" "password=" "menu:confirm"
register_cmd "access" "remove" "Remove access" "access_remove_handler" "login" "" "menu:internal-confirm"
register_cmd "access" "add-key" "Add SSH public key for access" "access_add_key_handler" "login pubkey-file" "" "menu:internal-confirm"
