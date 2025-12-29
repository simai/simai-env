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
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
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
  systemctl reload "$svc" || systemctl restart "$svc"
}

register_cmd "php" "list" "List installed PHP versions and FPM status" "php_list_handler" "" ""
register_cmd "php" "reload" "Reload or restart PHP-FPM for version" "php_reload_handler" "php" ""
