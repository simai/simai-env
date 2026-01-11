#!/usr/bin/env bash

validate_php_version() {
  local ver="$1"
  case "$ver" in
    8.1|8.2|8.3|8.4) return 0 ;;
    *) error "Unsupported PHP version '${ver}'. Allowed: 8.1, 8.2, 8.3, 8.4"; return 1 ;;
  esac
}

is_php_version_installed() {
  local ver="$1"
  if [[ -d "/etc/php/${ver}/fpm" ]] && { command -v "php${ver}" >/dev/null 2>&1 || command -v "php-fpm${ver}" >/dev/null 2>&1 || [[ -x "/usr/sbin/php-fpm${ver}" ]]; }; then
    return 0
  fi
  return 1
}

detect_missing_php_packages() {
  local ver="$1" include_common="${2:-yes}"
  local pkgs=("php${ver}-fpm" "php${ver}-cli" "php${ver}-common")
  if [[ "${include_common,,}" == "yes" ]]; then
    pkgs+=("php${ver}-curl" "php${ver}-mbstring" "php${ver}-xml" "php${ver}-zip" "php${ver}-gd" "php${ver}-intl" "php${ver}-mysql" "php${ver}-bcmath" "php${ver}-opcache")
  fi
  local missing=() pkg
  for pkg in "${pkgs[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  printf "%s\n" "${missing[@]}"
}
