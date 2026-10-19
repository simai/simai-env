#!/usr/bin/env bash

has_ondrej_php_repo() {
  if ls /etc/apt/sources.list.d/*ondrej*php*.list >/dev/null 2>&1; then return 0; fi
  if apt-cache policy php8.2-fpm 2>/dev/null | grep -qi "ondrej"; then return 0; fi
  return 1
}

# PHP of the Ubuntu release itself needs no repository; other versions come
# from ondrej/php, which covers a new Ubuntu release only some months later.
ensure_ondrej_php_repo() {
  local version="${1:-}" native
  [[ -n "${PLATFORM_OS_CODENAME:-}" ]] || platform_detect_os
  native=$(platform_native_php_version)
  [[ -n "$version" && "$version" == "$native" ]] && return 0
  if ! has_ondrej_php_repo; then
    if ! platform_ondrej_php_available; then
      error "PHP ${version:-<requested>} is not available on ${PLATFORM_OS_PRETTY:-this release}: ondrej/php has no packages for ${PLATFORM_OS_CODENAME:-it} yet.${native:+ Use PHP ${native} from the Ubuntu repository.}"
      return 1
    fi
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
