#!/usr/bin/env bash

has_ondrej_php_repo() {
  if ls /etc/apt/sources.list.d/*ondrej*php*.list >/dev/null 2>&1; then return 0; fi
  if apt-cache policy php8.2-fpm 2>/dev/null | grep -qi "ondrej"; then return 0; fi
  return 1
}

ensure_ondrej_php_repo() {
  if ! has_ondrej_php_repo; then
    info "Adding PPA:ondrej/php"
    os_cmd_pkg_update
    if ! run_long "apt-get update (pre repo add)" "${OS_CMD[@]}"; then
      error "Failed apt-get update before adding repository"
      return 1
    fi
    os_cmd_pkg_install software-properties-common ca-certificates lsb-release apt-transport-https
    if ! run_long "Installing repo dependencies" "${OS_CMD[@]}"; then
      error "Failed to install repo dependencies"
      return 1
    fi
    os_cmd_pkg_add_ppa "ppa:ondrej/php"
    if ! run_long "Adding ondrej/php PPA" "${OS_CMD[@]}"; then
      error "Failed to add PPA ondrej/php"
      return 1
    fi
    os_cmd_pkg_update
    if ! run_long "Updating apt indexes (ondrej/php)" "${OS_CMD[@]}"; then
      error "Failed apt-get update after adding repository"
      return 1
    fi
  fi
  return 0
}
