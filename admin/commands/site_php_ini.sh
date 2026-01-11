#!/usr/bin/env bash

site_php_ini_set_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local name="${PARSED_ARGS[name]:-}"
  local value="${PARSED_ARGS[value]:-}"
  local apply="${PARSED_ARGS[apply]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${apply,,}" == "yes" ]] && apply="yes" || apply="no"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 1
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
  fi
  if [[ -n "$domain" ]]; then
    PARSED_ARGS[domain]="$domain"
  fi
  domain="${PARSED_ARGS[domain]:-}"
  require_args "domain name value"
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1
  validate_ini_key "$name" || return 1
  validate_ini_value "$value" || return 1

  declare -A kv=()
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local k="${entry%%|*}"
    local v="${entry#*|}"
    kv["$k"]="$v"
  done < <(read_site_php_ini_overrides "$domain")
  kv["$name"]="$value"

  local out=()
  local k
  for k in "${!kv[@]}"; do
    out+=("${k}|${kv[$k]}")
  done
  write_site_php_ini_overrides "$domain" "${out[@]}"
  info "Set override ${name} for ${domain}"

  if [[ "$apply" == "yes" ]]; then
    if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
      error "Use --confirm yes to apply changes"
      return 1
    fi
    if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
      local choice
      choice=$(select_from_list "Apply and reload php-fpm now?" "no" "no" "yes")
      [[ "$choice" == "yes" ]] || return 0
    fi
    read_site_metadata "$domain"
    if ! load_profile "${SITE_META[profile]:-}"; then
      return 1
    fi
    if [[ "${SITE_META[php]:-none}" == "none" || "${SITE_META[php]:-}" == "" || "${PROFILE_REQUIRES_PHP:-no}" == "no" ]]; then
      warn "Profile does not use PHP for ${domain}; overrides stored but not applied"
      return 0
    fi
    local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]}}"
    if ! validate_project_slug "$socket_project"; then
      socket_project="$(project_slug_from_domain "$domain")"
    fi
    if ! apply_site_php_ini_overrides_to_pool "$domain" "${SITE_META[php]}" "$socket_project"; then
      return 1
    fi
  fi
}

site_php_ini_unset_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local name="${PARSED_ARGS[name]:-}"
  local apply="${PARSED_ARGS[apply]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${apply,,}" == "yes" ]] && apply="yes" || apply="no"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 1
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
  fi
  if [[ -n "$domain" ]]; then
    PARSED_ARGS[domain]="$domain"
  fi
  domain="${PARSED_ARGS[domain]:-}"
  require_args "domain name"
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1
  validate_ini_key "$name" || return 1

  declare -A kv=()
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local k="${entry%%|*}"
    local v="${entry#*|}"
    kv["$k"]="$v"
  done < <(read_site_php_ini_overrides "$domain")
  if [[ -z "${kv[$name]+x}" ]]; then
    info "Override ${name} not set for ${domain}"
  else
    unset 'kv["$name"]'
  fi
  local out=()
  local k
  for k in "${!kv[@]}"; do
    out+=("${k}|${kv[$k]}")
  done
  write_site_php_ini_overrides "$domain" "${out[@]}"

  if [[ "$apply" == "yes" ]]; then
    if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
      error "Use --confirm yes to apply changes"
      return 1
    fi
    if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
      local choice
      choice=$(select_from_list "Apply and reload php-fpm now?" "no" "no" "yes")
      [[ "$choice" == "yes" ]] || return 0
    fi
    read_site_metadata "$domain"
    if ! load_profile "${SITE_META[profile]:-}"; then
      return 1
    fi
    if [[ "${SITE_META[php]:-none}" == "none" || "${SITE_META[php]:-}" == "" || "${PROFILE_REQUIRES_PHP:-no}" == "no" ]]; then
      warn "Profile does not use PHP for ${domain}; overrides updated but not applied"
      return 0
    fi
    local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]}}"
    if ! validate_project_slug "$socket_project"; then
      socket_project="$(project_slug_from_domain "$domain")"
    fi
    if ! apply_site_php_ini_overrides_to_pool "$domain" "${SITE_META[php]}" "$socket_project"; then
      return 1
    fi
  fi
}

site_php_ini_list_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 1
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
  fi
  if [[ -n "$domain" ]]; then
    PARSED_ARGS[domain]="$domain"
  fi
  domain="${PARSED_ARGS[domain]:-}"
  require_args "domain"
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1
  local entries=()
  mapfile -t entries < <(read_site_php_ini_overrides "$domain")
  if [[ ${#entries[@]} -eq 0 ]]; then
    info "No overrides set for ${domain}"
    return 0
  fi
  local border="+--------------------------+----------------------+"
  printf "%s\n" "$border"
  printf "| %-24s | %-20s |\n" "Key" "Value"
  printf "%s\n" "$border"
  local entry
  for entry in "${entries[@]}"; do
    local key="${entry%%|*}"
    local val="${entry#*|}"
    printf "| %-24s | %-20s |\n" "$key" "$val"
  done
  printf "%s\n" "$border"
}

site_php_ini_apply_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 1
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
  fi
  if [[ -n "$domain" ]]; then
    PARSED_ARGS[domain]="$domain"
  fi
  domain="${PARSED_ARGS[domain]:-}"
  require_args "domain"
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply changes"
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Apply overrides and reload php-fpm now?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || return 0
  fi

  read_site_metadata "$domain"
  if ! load_profile "${SITE_META[profile]:-}"; then
    return 1
  fi
  if [[ "${SITE_META[php]:-none}" == "none" || "${SITE_META[php]:-}" == "" || "${PROFILE_REQUIRES_PHP:-no}" == "no" ]]; then
    warn "Profile does not use PHP for ${domain}; nothing to apply"
    return 0
  fi
  local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]}}"
  if ! validate_project_slug "$socket_project"; then
    socket_project="$(project_slug_from_domain "$domain")"
  fi
  if ! apply_site_php_ini_overrides_to_pool "$domain" "${SITE_META[php]}" "$socket_project"; then
    return 1
  fi
}

register_cmd "site" "php-ini-set" "Set per-site PHP ini override (stored; optional apply)" "site_php_ini_set_handler" "domain name value" "apply=no confirm=" "tier:advanced"
register_cmd "site" "php-ini-unset" "Remove per-site PHP ini override" "site_php_ini_unset_handler" "domain name" "apply=no confirm=" "tier:advanced"
register_cmd "site" "php-ini-list" "List per-site PHP ini overrides" "site_php_ini_list_handler" "domain" "" "tier:advanced"
register_cmd "site" "php-ini-apply" "Apply stored per-site PHP ini overrides to current pool" "site_php_ini_apply_handler" "domain" "confirm=" "tier:advanced"
