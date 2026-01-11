#!/usr/bin/env bash

site_db_export_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local target="${PARSED_ARGS[target]:-.env}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 1
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
    PARSED_ARGS[domain]="$domain"
  fi
  require_args "domain"
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to export credentials."
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Write DB_* to ${target}?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || return 0
  fi

  local project_dir="${WWW_ROOT}/${domain}"
  if [[ ! -d "$project_dir" ]]; then
    warn "Project directory ${project_dir} not found; creating"
    mkdir -p "$project_dir"
    chown "${SIMAI_USER}:${SIMAI_USER}" "$project_dir" 2>/dev/null || true
  fi
  if ! site_db_export_to_env "$domain" "$project_dir" "$target"; then
    return 1
  fi
  echo "DB credentials written to ${project_dir}/${target} (owner ${SIMAI_USER}, mode 0640)"
}

register_cmd "site" "db-export" "Export DB creds into project .env" "site_db_export_handler" "" "domain= target= confirm=" "tier:advanced"
