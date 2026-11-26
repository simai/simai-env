#!/usr/bin/env bash

SIMAI_DEFAULT_PHP_VERSION=${SIMAI_DEFAULT_PHP_VERSION:-8.2}
# The one list of PHP versions sites may still use although PHP no longer
# fixes them (no security fixes): plans and JSON mark them "outdated". The
# Python readers (lib/php_support.py) take these two lines from this file.
# shellcheck disable=SC2034 # read by lib/php_support.py too
SIMAI_PHP_OUTDATED="7.4 8.0"
# Older versions are refused everywhere (php install, site add, set-php).
SIMAI_PHP_MIN_SUPPORTED="7.4"

php_default_version() {
  echo "$SIMAI_DEFAULT_PHP_VERSION"
}

validate_php_version_syntax() {
  local ver="$1"
  if [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  error "Invalid PHP version '${ver}'. Use format X.Y, for example 8.2."
  return 1
}

# Whether simai-env marks this PHP version outdated (SIMAI_PHP_OUTDATED).
php_version_outdated() {
  [[ " ${SIMAI_PHP_OUTDATED} " == *" ${1:-} "* ]]
}

# Refuse a version older than SIMAI_PHP_MIN_SUPPORTED.
php_version_supported() {
  local ver="$1"
  validate_php_version_syntax "$ver" || return 1
  php_version_gte "$ver" "$SIMAI_PHP_MIN_SUPPORTED" && return 0
  error "PHP ${ver} is not supported: the oldest PHP simai-env runs is ${SIMAI_PHP_MIN_SUPPORTED}"
  return 1
}

# The note plans and commands carry for an outdated version (a warning, so a
# plan lists it under plan_checks.notes).
php_outdated_note() {
  php_version_outdated "${1:-}" || return 0
  warn "PHP ${1} is outdated and no longer gets security fixes"
}

php_pick_preferred_version() {
  local preferred
  preferred=$(php_default_version)
  local versions=("$@")
  local ver
  for ver in "${versions[@]}"; do
    if [[ "$ver" == "$preferred" ]]; then
      echo "$preferred"
      return 0
    fi
  done
  if [[ ${#versions[@]} -eq 0 ]]; then
    return 1
  fi
  echo "${versions[$((${#versions[@]} - 1))]}"
}

php_list_available_install_versions() {
  local versions=()
  if command -v apt-cache >/dev/null 2>&1; then
    local pkg ver
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      if [[ "$pkg" =~ ^php([0-9]+\.[0-9]+)-fpm$ ]]; then
        ver="${BASH_REMATCH[1]}"
        versions+=("$ver")
      fi
    done < <(apt-cache pkgnames 2>/dev/null | grep -E '^php[0-9]+\.[0-9]+-fpm$' | sort -u)
  fi
  if [[ ${#versions[@]} -eq 0 ]]; then
    mapfile -t versions < <(installed_php_versions)
  fi
  if [[ ${#versions[@]} -eq 0 ]]; then
    return 0
  fi
  local v
  for v in "${versions[@]}"; do
    if php_version_gte "$v" "$SIMAI_PHP_MIN_SUPPORTED"; then printf "%s\n" "$v"; fi
  done | sort -V -u
}

php_version_gte() {
  local lhs="$1" rhs="$2"
  [[ "$lhs" == "$rhs" ]] && return 0
  [[ "$(printf "%s\n%s\n" "$rhs" "$lhs" | sort -V | tail -n 1)" == "$lhs" ]]
}

php_version_lte() {
  local lhs="$1" rhs="$2"
  [[ "$lhs" == "$rhs" ]] && return 0
  [[ "$(printf "%s\n%s\n" "$lhs" "$rhs" | sort -V | head -n 1)" == "$lhs" ]]
}

php_filter_versions() {
  local explicit_csv="$1" min_version="$2" max_version="$3"
  shift 3
  local versions=("$@")
  local explicit=()
  if [[ -n "$explicit_csv" ]]; then
    IFS=' ' read -r -a explicit <<<"$explicit_csv"
  fi
  local filtered=()
  local ver allowed
  for ver in "${versions[@]}"; do
    [[ -z "$ver" ]] && continue
    allowed=0
    if [[ ${#explicit[@]} -gt 0 ]]; then
      local item
      for item in "${explicit[@]}"; do
        if [[ "$ver" == "$item" ]]; then
          allowed=1
          break
        fi
      done
    else
      allowed=1
      if [[ -n "$min_version" ]] && ! php_version_gte "$ver" "$min_version"; then
        allowed=0
      fi
      if [[ -n "$max_version" ]] && ! php_version_lte "$ver" "$max_version"; then
        allowed=0
      fi
    fi
    [[ $allowed -eq 1 ]] && filtered+=("$ver")
  done
  # Nothing allowed prints nothing: an empty line would read as one version.
  (( ${#filtered[@]} )) || return 0
  printf "%s\n" "${filtered[@]}"
}

php_describe_constraints() {
  local explicit_csv="$1" min_version="$2" max_version="$3"
  if [[ -n "$explicit_csv" ]]; then
    echo "$explicit_csv"
    return 0
  fi
  if [[ -n "$min_version" && -n "$max_version" ]]; then
    echo "${min_version}-${max_version}"
    return 0
  fi
  if [[ -n "$min_version" ]]; then
    echo ">=${min_version}"
    return 0
  fi
  if [[ -n "$max_version" ]]; then
    echo "<=${max_version}"
    return 0
  fi
  echo "any"
}

validate_php_version() {
  local ver="$1"
  validate_php_version_syntax "$ver" || return 1
  return 0
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
    pkgs+=("php${ver}-curl" "php${ver}-mbstring" "php${ver}-xml" "php${ver}-zip" "php${ver}-gd" "php${ver}-intl" "php${ver}-mysql" "php${ver}-bcmath" "php${ver}-redis")
    # PHP 8.5 builds OPcache into the core; earlier versions package it.
    [[ "$(printf '%s\n8.5\n' "$ver" | sort -V | head -n1)" == 8.5 ]] || pkgs+=("php${ver}-opcache")
  fi
  local missing=() pkg
  for pkg in "${pkgs[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  printf "%s\n" "${missing[@]}"
}
