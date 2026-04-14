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

ensure_profile_writable_paths() {
  local project_root="$1"
  local path
  for path in "${PROFILE_WRITABLE_PATHS[@]}"; do
    [[ -z "$path" ]] && continue
    mkdir -p "${project_root}/${path}"
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
  local allowed_csv="${allowed[*]}"
  local min_allowed="${PROFILE_ALLOWED_PHP_MIN_VERSION:-}"
  local max_allowed="${PROFILE_ALLOWED_PHP_MAX_VERSION:-}"
  local allowed_desc=""
  local selected=""
  allowed_desc=$(php_describe_constraints "$allowed_csv" "$min_allowed" "$max_allowed")

  if [[ -n "$desired" ]]; then
    local desired_allowed=()
    mapfile -t desired_allowed < <(php_filter_versions "$allowed_csv" "$min_allowed" "$max_allowed" "$desired")
    if [[ ${#desired_allowed[@]} -eq 0 ]]; then
      error "PHP ${desired} is not allowed for profile ${PROFILE_ID:-unknown}. Allowed: ${allowed_desc}"
      return 1
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
    local installed=()
    local candidates=()
    mapfile -t installed < <(installed_php_versions)
    if [[ ${#installed[@]} -eq 0 ]]; then
      error "No PHP versions are installed. Install one first: simai-admin.sh php install --php $(php_default_version)"
      return 1
    fi
    mapfile -t candidates < <(php_filter_versions "$allowed_csv" "$min_allowed" "$max_allowed" "${installed[@]}")
    if [[ ${#candidates[@]} -eq 0 ]]; then
      error "No installed PHP versions match profile ${PROFILE_ID:-unknown}. Allowed: ${allowed_desc}. Install one first: simai-admin.sh php install --php $(php_default_version)"
      return 1
    fi
    local default_sel=""
    default_sel=$(php_pick_preferred_version "${candidates[@]}")
    selected=$(select_from_list "Select PHP version" "$default_sel" "${candidates[@]}")
    if [[ -z "$selected" ]]; then
      command_cancelled
      return $?
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
  mapfile -t choices < <(php_filter_versions "$allowed_csv" "$min_allowed" "$max_allowed" "${versions[@]}")

  if [[ ${#choices[@]} -eq 0 ]]; then
    error "No installed PHP versions match allowed rule: ${allowed_desc}"
    return 1
  fi

  selected=$(php_pick_preferred_version "${choices[@]}")

  echo "$selected"
}

decide_create_db_for_profile() {
  local create_db="${PARSED_ARGS[create-db]:-${PARSED_ARGS[db]:-}}"
  local skip_db_required="${PARSED_ARGS[skip-db-required]:-no}"
  [[ "${skip_db_required,,}" != "yes" ]] && skip_db_required="no"
  case "${PROFILE_REQUIRES_DB:-no}" in
    no)
      echo "no"
      return 0
      ;;
    required)
      if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "$create_db" ]]; then
        local choice
        choice=$(select_from_list \
          "Database setup for this site" \
          "create-managed-db" \
          "create-managed-db" \
          "continue-without-db")
        if [[ -z "$choice" ]]; then
          command_cancelled
          return $?
        fi
        case "$choice" in
          create-managed-db) create_db="yes" ;;
          continue-without-db) create_db="no" ;;
        esac
      fi
      [[ -z "$create_db" ]] && create_db="yes"
      if [[ "${create_db,,}" != "yes" ]]; then
        if [[ "$skip_db_required" == "yes" ]]; then
          warn "Database is required for profile ${PROFILE_ID:-unknown}; skipped by --skip-db-required yes. Create later: simai-admin.sh site db-create --domain ${PARSED_ARGS[domain]:-unknown} --confirm yes"
          echo "no"
          return 0
        else
          error "Database is required for profile ${PROFILE_ID:-unknown}; use --create-db yes (or --db yes)"
          return 1
        fi
      fi
      ;;
    optional)
      if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "$create_db" ]]; then
        local choice
        choice=$(select_from_list \
          "Database setup for this site" \
          "continue-without-db" \
          "continue-without-db" \
          "create-managed-db")
        if [[ -z "$choice" ]]; then
          command_cancelled
          return $?
        fi
        case "$choice" in
          create-managed-db) create_db="yes" ;;
          continue-without-db) create_db="no" ;;
        esac
      fi
      [[ -z "$create_db" ]] && create_db="no"
      ;;
  esac
  [[ "${create_db,,}" == "yes" ]] && echo "yes" || echo "no"
}
