#!/usr/bin/env bash
set -euo pipefail

php_list_handler() {
  local versions=()
  mapfile -t versions < <(installed_php_versions)
  if [[ ${#versions[@]} -eq 0 ]]; then
    info "No PHP versions found under /etc/php"
    return
  fi

  local border="+----------+--------------+------------+"
  printf "%s\n" "$border"
  printf "| %-8s | %-12s | %-10s |\n" "Version" "FPM status" "Pool count"
  printf "%s\n" "$border"
  for v in "${versions[@]}"; do
    local svc="php${v}-fpm"
    local status
    if os_svc_is_active "$svc"; then
      status="active"
    else
      status="inactive"
    fi
    local pool_dir="/etc/php/${v}/fpm/pool.d"
    local pool_count=0
    if [[ -d "$pool_dir" ]]; then
      pool_count=$(find "$pool_dir" -maxdepth 1 -type f -name "*.conf" ! -name "www.conf" 2>/dev/null | wc -l | tr -d ' ')
    fi
    printf "| %-8s | %-10s | %-10s |\n" "$v" "$status" "$pool_count"
  done
  printf "%s\n" "$border"
}

php_reload_handler() {
  parse_kv_args "$@"
  local php_version="${PARSED_ARGS[php]:-}"
  if [[ -z "$php_version" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local versions=()
    mapfile -t versions < <(installed_php_versions)
    php_version=$(select_from_list "Select PHP version to reload" "" "${versions[@]}")
  fi
  if [[ -z "$php_version" ]]; then
    require_args "php"
  fi
  [[ -z "$php_version" ]] && return 1
  local svc="php${php_version}-fpm"
  info "Reloading ${svc}"
  os_svc_reload_or_restart "$svc"
}

php_install_handler() {
  parse_kv_args "$@"
  local php_version="${PARSED_ARGS[php]:-}"
  local include_common="${PARSED_ARGS[include-common]:-yes}"
  local confirm="${PARSED_ARGS[confirm]:-no}"

  if [[ -z "$php_version" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    php_version=$(select_from_list "Select PHP version to install" "8.2" "8.1" "8.2" "8.3" "8.4")
  fi
  if [[ -z "$php_version" ]]; then
    require_args "php"
  fi

  include_common=$([[ "${include_common,,}" == "no" ]] && echo "no" || echo "yes")

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Install common extensions?" "yes" "yes" "no")
    include_common="$choice"
    local proceed
    proceed=$(select_from_list "Proceed with installation?" "no" "no" "yes")
    if [[ "$proceed" != "yes" ]]; then
      info "Installation cancelled"
      return 0
    fi
  fi

  if ! validate_php_version "$php_version"; then
    return 1
  fi

  local missing_pkgs=()
  mapfile -t missing_pkgs < <(detect_missing_php_packages "$php_version" "$include_common")
  local total_steps=4
  [[ ${#missing_pkgs[@]} -gt 0 ]] && total_steps=7
  progress_init "$total_steps"
  progress_step "Checking current PHP installation"

  if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
    progress_step "Testing php-fpm${php_version} configuration"
  else
    if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "${confirm,,}" != "yes" ]]; then
      error "Will install packages: ${missing_pkgs[*]}. Re-run with --confirm yes to proceed."
      return 1
    fi
    progress_step "Ensuring ondrej/php repository"
    if ! ensure_ondrej_php_repo; then
      return 1
    fi
    progress_step "Updating apt indexes"
    os_cmd_pkg_update
    if ! run_long "Updating apt indexes" "${OS_CMD[@]}"; then
      return 1
    fi

    progress_step "Installing PHP ${php_version} packages"
    os_cmd_pkg_install "${missing_pkgs[@]}"
    if ! run_long "Installing PHP ${php_version}" "${OS_CMD[@]}"; then
      return 1
    fi
    progress_step "Testing php-fpm${php_version} configuration"
  fi

  local fpm_bin_path=""
  fpm_bin_path=$(command -v "php-fpm${php_version}" 2>/dev/null || true)
  if [[ -z "$fpm_bin_path" && -x "/usr/sbin/php-fpm${php_version}" ]]; then
    fpm_bin_path="/usr/sbin/php-fpm${php_version}"
  fi
  if [[ -n "$fpm_bin_path" ]]; then
    if ! "$fpm_bin_path" -t >>"$LOG_FILE" 2>&1; then
      error "php-fpm${php_version} config test failed. See ${LOG_FILE}"
      return 1
    fi
  else
    error "php-fpm${php_version} binary not found after install"
    return 1
  fi

  progress_step "Enabling php${php_version}-fpm service"
  if ! os_svc_enable_now "php${php_version}-fpm"; then
    error "Failed to enable/start php${php_version}-fpm. See ${LOG_FILE}"
    return 1
  fi

  progress_step "Verifying php${php_version}-fpm status"
  local svc_status
  if os_svc_is_active "php${php_version}-fpm"; then
    svc_status="active"
  else
    svc_status="inactive"
  fi
  if [[ "$svc_status" != "active" ]]; then
    error "php${php_version}-fpm service is ${svc_status}"
    return 1
  fi

  progress_done "PHP ${php_version} installation complete"
  echo "===== PHP install summary ====="
  echo "PHP version : ${php_version}"
  echo "Packages    : $([[ ${#missing_pkgs[@]} -gt 0 ]] && echo "${missing_pkgs[*]}" || echo none)"
  echo "php binary  : $(command -v "php${php_version}" || echo missing)"
  echo "php-fpm bin : ${fpm_bin_path:-missing}"
  echo "Service     : ${svc_status}"
  echo "Next steps  : To switch a site, run: simai-admin.sh site set-php --domain <domain> --php ${php_version}"
}

register_cmd "php" "list" "List installed PHP versions and FPM status" "php_list_handler" "" ""
register_cmd "php" "reload" "Reload or restart PHP-FPM for version" "php_reload_handler" "php" ""
register_cmd "php" "install" "Install a PHP version (FPM/CLI + base extensions)" "php_install_handler" "" "php= include-common= confirm="
