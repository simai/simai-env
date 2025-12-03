#!/usr/bin/env bash
set -euo pipefail

php_list_handler() {
  local versions=()
  shopt -s nullglob
  for d in /etc/php/*; do
    [[ -d "$d" ]] || continue
    versions+=("$(basename "$d")")
  done
  shopt -u nullglob

  if [[ ${#versions[@]} -eq 0 ]]; then
    info "No PHP versions found under /etc/php"
    return
  fi

  info "Installed PHP versions:"
  for v in "${versions[@]}"; do
    local svc="php${v}-fpm"
    local status
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    echo "  ${v}: fpm ${status}"
  done
}

php_reload_handler() {
  parse_kv_args "$@"
  require_args "php"
  local php_version="${PARSED_ARGS[php]}"
  local svc="php${php_version}-fpm"
  info "Reloading ${svc}"
  systemctl reload "$svc" || systemctl restart "$svc"
}

register_cmd "php" "list" "List installed PHP versions and FPM status" "php_list_handler" "" ""
register_cmd "php" "reload" "Reload or restart PHP-FPM for version" "php_reload_handler" "php" ""
