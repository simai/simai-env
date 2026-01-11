#!/usr/bin/env bash

# Resolves PROFILE_NGINX_TEMPLATE to a full path under templates/
resolve_profile_nginx_template_path() {
  local tmpl="${PROFILE_NGINX_TEMPLATE:-}"
  if [[ -z "$tmpl" ]]; then
    error "PROFILE_NGINX_TEMPLATE is not set for profile ${PROFILE_ID:-unknown}"
    return 1
  fi
  if [[ "$tmpl" == */* || "$tmpl" == ".."* ]]; then
    error "Invalid nginx template name ${tmpl} (must be a filename under templates)"
    return 1
  fi
  local path="${SCRIPT_DIR}/templates/${tmpl}"
  if [[ ! -f "$path" ]]; then
    error "nginx template not found: ${path}"
    return 1
  fi
  echo "$path"
}

ensure_profile_public_dir() {
  local project_root="$1"
  local public_dir="${PROFILE_PUBLIC_DIR}"
  local doc_root
  doc_root=$(site_compute_doc_root "$project_root" "$public_dir") || return 1
  mkdir -p "$doc_root"
}

ensure_profile_bootstrap_files() {
  local project_root="$1"
  local placeholder_php='<?php http_response_code(200); echo "SIMAI placeholder"; ?>'
  local placeholder_html='<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>SIMAI placeholder</title></head>
<body><h1>It works</h1><p>SIMAI placeholder page.</p></body></html>'
  local file
  for file in "${PROFILE_BOOTSTRAP_FILES[@]}"; do
    [[ -z "$file" ]] && continue
    local dst="${project_root}/${file}"
    mkdir -p "$(dirname "$dst")"
    if [[ ! -f "$dst" ]]; then
      case "$dst" in
        *.php) printf "%s\n" "$placeholder_php" >"$dst" ;;
        *.html) printf "%s\n" "$placeholder_html" >"$dst" ;;
        *) printf "SIMAI placeholder\n" >"$dst" ;;
      esac
    fi
  done
}

ensure_profile_required_markers() {
  local project_root="$1"
  local missing=()
  local marker
  for marker in "${PROFILE_REQUIRED_MARKERS[@]}"; do
    [[ -z "$marker" ]] && continue
    if [[ ! -e "${project_root}/${marker}" ]]; then
      missing+=("$marker")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Required files for profile ${PROFILE_ID:-unknown} are missing: ${missing[*]}"
    return 1
  fi
  return 0
}

select_php_version_for_profile() {
  local desired="$1"
  local allowed=("${PROFILE_ALLOWED_PHP_VERSIONS[@]}")
  local selected=""

  if [[ -n "$desired" ]]; then
    if [[ ${#allowed[@]} -gt 0 ]]; then
      local ok=1
      local v
      for v in "${allowed[@]}"; do
        if [[ "$v" == "$desired" ]]; then ok=0; fi
      done
      if [[ $ok -ne 0 ]]; then
        error "PHP ${desired} is not allowed for profile ${PROFILE_ID:-unknown}. Allowed: ${allowed[*]}"
        return 1
      fi
    fi
    if ! is_php_version_installed "$desired"; then
      if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
        local choice
        choice=$(select_from_list "PHP ${desired} is not installed. Install now?" "no" "no" "yes")
        if [[ "$choice" == "yes" ]]; then
          if ! run_command "php" "install" --php "$desired"; then
            error "Failed to install PHP ${desired}"
            return 1
          fi
          if ! is_php_version_installed "$desired"; then
            error "PHP ${desired} installation did not complete; version still missing."
            return 1
          fi
        else
          error "PHP ${desired} is not installed. Install it first: simai-admin.sh php install --php ${desired}"
          return 1
        fi
      else
        error "PHP ${desired} is not installed. Install it first: simai-admin.sh php install --php ${desired}"
        return 1
      fi
    fi
    echo "$desired"
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local candidates=()
    if [[ ${#allowed[@]} -gt 0 ]]; then
      candidates=("${allowed[@]}")
    else
      candidates=("8.1" "8.2" "8.3" "8.4")
    fi
    local default_sel=""
    if printf '%s\n' "${candidates[@]}" | grep -qx "8.2" && is_php_version_installed "8.2"; then
      default_sel="8.2"
    else
      local c
      for c in "${candidates[@]}"; do
        if is_php_version_installed "$c"; then
          default_sel="$c"
          break
        fi
      done
    fi
    [[ -z "$default_sel" ]] && default_sel="${candidates[0]}"
    selected=$(select_from_list "Select PHP version" "$default_sel" "${candidates[@]}")
    [[ -z "$selected" ]] && selected="$default_sel"
    if ! is_php_version_installed "$selected"; then
      local choice
      choice=$(select_from_list "PHP ${selected} is not installed. Install now?" "no" "no" "yes")
      if [[ "$choice" == "yes" ]]; then
        if ! run_command "php" "install" --php "$selected"; then
          error "Failed to install PHP ${selected}"
          return 1
        fi
        if ! is_php_version_installed "$selected"; then
          error "PHP ${selected} installation did not complete; version still missing."
          return 1
        fi
      else
        error "PHP ${selected} is not installed. Install it first: simai-admin.sh php install --php ${selected}"
        return 1
      fi
    fi
    echo "$selected"
    return 0
  fi

  local versions=()
  mapfile -t versions < <(installed_php_versions)
  if [[ ${#versions[@]} -eq 0 ]]; then
    error "No PHP versions installed"
    return 1
  fi

  local choices=()
  if [[ ${#allowed[@]} -gt 0 ]]; then
    local v
    for v in "${versions[@]}"; do
      for a in "${allowed[@]}"; do
        if [[ "$v" == "$a" ]]; then
          choices+=("$v")
        fi
      done
    done
  else
    choices=("${versions[@]}")
  fi

  if [[ ${#choices[@]} -eq 0 ]]; then
    error "No installed PHP versions match allowed list: ${allowed[*]}"
    return 1
  fi

  if printf '%s\n' "${choices[@]}" | grep -qx "8.2"; then
    selected="8.2"
  else
    selected="${choices[0]}"
  fi

  echo "$selected"
}

decide_create_db_for_profile() {
  local create_db="${PARSED_ARGS[create-db]:-}"
  local skip_db_required="${PARSED_ARGS[skip-db-required]:-no}"
  [[ "${skip_db_required,,}" != "yes" ]] && skip_db_required="no"
  case "${PROFILE_REQUIRES_DB:-no}" in
    no)
      echo "no"
      return 0
      ;;
    required)
      if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "$create_db" ]]; then
        create_db=$(select_from_list "Create MySQL database and user?" "yes" "yes" "no")
      fi
      [[ -z "$create_db" ]] && create_db="yes"
      if [[ "${create_db,,}" != "yes" ]]; then
        if [[ "$skip_db_required" == "yes" ]]; then
          warn "Database is required for profile ${PROFILE_ID:-unknown}; skipped by --skip-db-required yes. Create later: simai-admin.sh site db-create --domain ${PARSED_ARGS[domain]:-unknown} --confirm yes"
          echo "no"
          return 0
        else
          error "Database is required for profile ${PROFILE_ID:-unknown}; use --create-db yes"
          return 1
        fi
      fi
      ;;
    optional)
      if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "$create_db" ]]; then
        create_db=$(select_from_list "Create MySQL database and user?" "no" "no" "yes")
      fi
      [[ -z "$create_db" ]] && create_db="no"
      ;;
  esac
  [[ "${create_db,,}" == "yes" ]] && echo "yes" || echo "no"
}
