#!/usr/bin/env bash

fix_resolve_effective_project_and_socket() {
  local domain="$1" project="$2" socket_project="$3"
  local effective_project="$project"
  if ! validate_project_slug "$effective_project"; then
    effective_project=$(project_slug_from_domain "$domain")
    warn "Project slug '${project}' is invalid; using safe slug ${effective_project} for derived paths"
  fi
  if [[ -z "$socket_project" ]] || ! validate_project_slug "$socket_project"; then
    socket_project="$effective_project"
  fi
  echo "${effective_project}|${socket_project}"
}

fix_resolve_pool_file() {
  local php_version="$1" socket_project="$2"
  local pool_file="/etc/php/${php_version}/fpm/pool.d/${socket_project}.conf"
  if [[ ! -f "$pool_file" ]]; then
    error "Pool config missing: ${pool_file}. Create/recreate pool (site add / set-php) first."
    return 1
  fi
  echo "$pool_file"
}

fix_php_fpm_test() {
  local php_version="$1"
  local tester=""
  if command -v "php-fpm${php_version}" >/dev/null 2>&1; then
    tester="php-fpm${php_version}"
  elif [[ -x "/usr/sbin/php-fpm${php_version}" ]]; then
    tester="/usr/sbin/php-fpm${php_version}"
  fi
  if [[ -z "$tester" ]]; then
    warn "php-fpm${php_version} binary not found; skipping config test"
    return 0
  fi
  if ! "$tester" -t >>"$LOG_FILE" 2>&1; then
    return 1
  fi
  return 0
}

fix_reload_php_fpm() {
  local php_version="$1"
  if os_svc_reload "php${php_version}-fpm" >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  if os_svc_restart "php${php_version}-fpm" >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  error "Failed to reload/restart php${php_version}-fpm (see ${LOG_FILE})"
  return 1
}
