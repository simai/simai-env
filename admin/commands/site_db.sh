#!/usr/bin/env bash

site_db_status_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
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
  local db_name="" db_user="" db_charset="" db_collation=""
  if read_env=$(read_site_db_env "$domain"); then
    while IFS= read -r entry; do
      local k="${entry%%|*}" v="${entry#*|}"
      case "$k" in
        DB_NAME) db_name="$v" ;;
        DB_USER) db_user="$v" ;;
        DB_CHARSET) db_charset="$v" ;;
        DB_COLLATION) db_collation="$v" ;;
      esac
    done <<<"$read_env"
  fi
  echo "Site: ${domain}"
  if [[ -z "$db_name" ]]; then
    echo "db.env    : not present"
  else
    echo "db.env    : present"
    echo "DB_NAME   : ${db_name}"
    echo "DB_USER   : ${db_user}"
    echo "DB_HOST   : localhost"
    echo "DB_CHARSET: ${db_charset:-utf8mb4}"
    echo "DB_COLL   : ${db_collation:-utf8mb4_unicode_ci}"
  fi
  if [[ -n "$db_name" ]]; then
    if db_exists "$db_name"; then
      echo "Database  : exists"
    else
      echo "Database  : missing"
    fi
  fi
  if [[ -n "$db_user" ]]; then
    if db_user_exists "$db_user"; then
      echo "User      : exists"
      if [[ -n "$db_name" ]]; then
        if db_user_has_grant_on "$db_user" "$db_name"; then
          echo "Grants    : present on ${db_name}"
        else
          echo "Grants    : missing on ${db_name}"
        fi
      fi
    else
      echo "User      : missing"
    fi
  fi
}

site_db_create_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local dry_run="${PARSED_ARGS[dry_run]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${dry_run,,}" == "yes" ]] && dry_run="yes" || dry_run="no"
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
  read_site_metadata "$domain"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  if ! load_profile "${SITE_META[profile]:-}"; then
    return 1
  fi
  if [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]]; then
    error "Profile ${SITE_META[profile]:-} does not require DB; creation blocked."
    return 1
  fi

  local charset="${PROFILE_DB_CHARSET:-utf8mb4}"
  local coll="${PROFILE_DB_COLLATION:-utf8mb4_unicode_ci}"
  site_db_load_or_generate_creds "$domain" "$project" "$charset" "$coll" || return 1

  local privs=()
  if [[ -n "${PROFILE_DB_REQUIRED_PRIVILEGES+x}" && ${#PROFILE_DB_REQUIRED_PRIVILEGES[@]} -gt 0 ]]; then
    privs=("${PROFILE_DB_REQUIRED_PRIVILEGES[@]}")
  else
    mapfile -t privs < <(db_default_privileges)
  fi
  local priv_str
  priv_str=$(printf "%s, " "${privs[@]}")
  priv_str="${priv_str%, }"

  echo "Plan for ${domain}:"
  echo "- DB name : ${DB_CREDS_NAME}"
  echo "- DB user : ${DB_CREDS_USER}@localhost"
  echo "- Charset : ${DB_CREDS_CHARSET}"
  echo "- Collation: ${DB_CREDS_COLLATION}"
  echo "- Privileges: ${priv_str}"
  if [[ "$dry_run" == "yes" ]]; then
    echo "Dry-run only; no changes made."
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to create database resources."
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Proceed with DB/user creation?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || return 0
  fi

  if ! site_db_apply_create "$domain" "$DB_CREDS_NAME" "$DB_CREDS_USER" "$DB_CREDS_PASS" "$DB_CREDS_CHARSET" "$DB_CREDS_COLLATION" "${privs[@]}"; then
    return 1
  fi

  echo "Database created for ${domain}"
  echo "DB_NAME=${DB_CREDS_NAME}"
  echo "DB_USER=${DB_CREDS_USER}"
  echo "DB_PASS=${DB_CREDS_PASS}"
  echo "DB_HOST=localhost"
  return 0
}

site_db_drop_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local dry_run="${PARSED_ARGS[dry_run]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local remove_files="${PARSED_ARGS[remove_files]:-no}"
  [[ "${dry_run,,}" == "yes" ]] && dry_run="yes" || dry_run="no"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"
  [[ "${remove_files,,}" == "yes" ]] && remove_files="yes" || remove_files="no"

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
  read_site_metadata "$domain"
  if ! load_profile "${SITE_META[profile]:-}"; then
    return 1
  fi
  if [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]]; then
    error "Profile ${SITE_META[profile]:-} does not use DB; drop blocked."
    return 1
  fi
  if [[ "${PROFILE_ALLOW_DB_REMOVAL:-no}" != "yes" ]]; then
    error "Profile ${SITE_META[profile]:-} does not allow DB removal (PROFILE_ALLOW_DB_REMOVAL!=yes)."
    return 1
  fi

  local db_name="" db_user=""
  if read_env=$(read_site_db_env "$domain"); then
    while IFS= read -r entry; do
      local k="${entry%%|*}" v="${entry#*|}"
      case "$k" in
        DB_NAME) db_name="$v" ;;
        DB_USER) db_user="$v" ;;
      esac
    done <<<"$read_env"
  fi
  if [[ -z "$db_name" || -z "$db_user" ]]; then
    error "db.env not found or incomplete for ${domain}; cannot drop."
    return 1
  fi
  if ! db_validate_db_name "$db_name"; then return 1; fi
  if ! db_validate_db_user "$db_user"; then return 1; fi

  echo "Plan to drop DB resources for ${domain}:"
  echo "- Drop database: ${db_name}"
  echo "- Drop user    : ${db_user}@localhost"
  [[ "$remove_files" == "yes" ]] && echo "- Remove db.env file"
  if [[ "$dry_run" == "yes" ]]; then
    echo "Dry-run only; no changes made."
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to drop database resources."
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Proceed with drop?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || return 0
  fi

  if ! site_db_apply_drop "$domain" "$db_name" "$db_user" "$remove_files"; then
    return 1
  fi
  echo "Database resources dropped for ${domain}"
}

site_db_rotate_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local dry_run="${PARSED_ARGS[dry_run]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${dry_run,,}" == "yes" ]] && dry_run="yes" || dry_run="no"
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
  read_site_metadata "$domain"
  if ! load_profile "${SITE_META[profile]:-}"; then
    return 1
  fi
  if [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]]; then
    error "Profile ${SITE_META[profile]:-} does not use DB; rotation blocked."
    return 1
  fi

  local db_name="" db_user="" db_charset="utf8mb4" db_coll="utf8mb4_unicode_ci"
  if read_env=$(read_site_db_env "$domain"); then
    while IFS= read -r entry; do
      local k="${entry%%|*}" v="${entry#*|}"
      case "$k" in
        DB_NAME) db_name="$v" ;;
        DB_USER) db_user="$v" ;;
        DB_CHARSET) db_charset="$v" ;;
        DB_COLLATION) db_coll="$v" ;;
      esac
    done <<<"$read_env"
  fi
  if [[ -z "$db_name" || -z "$db_user" ]]; then
    error "db.env not found or incomplete for ${domain}; cannot rotate."
    return 1
  fi
  if ! db_validate_db_name "$db_name"; then return 1; fi
  if ! db_validate_db_user "$db_user"; then return 1; fi

  echo "Plan to rotate password for ${db_user}@localhost on ${db_name}"
  if [[ "$dry_run" == "yes" ]]; then
    echo "Dry-run only; no changes made."
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to rotate password."
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Proceed with password rotation?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || return 0
  fi

  local new_pass
  new_pass=$(generate_password)
  if ! site_db_apply_rotate "$domain" "$db_name" "$db_user" "$new_pass" "$db_charset" "$db_coll"; then
    return 1
  fi
  echo "Password rotated for ${db_user}"
  echo "DB_NAME=${db_name}"
  echo "DB_USER=${db_user}"
  echo "DB_PASS=${new_pass}"
  echo "DB_HOST=localhost"
}

register_cmd "site" "db-status" "Show DB status for a site" "site_db_status_handler" "" "domain="
register_cmd "site" "db-create" "Create DB + user for a site" "site_db_create_handler" "" "domain= dry_run= confirm="
register_cmd "site" "db-drop" "Drop DB + user for a site" "site_db_drop_handler" "" "domain= dry_run= confirm= remove_files="
register_cmd "site" "db-rotate" "Rotate DB user password for a site" "site_db_rotate_handler" "" "domain= dry_run= confirm="
