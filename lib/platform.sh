#!/usr/bin/env bash

platform_detect_os() {
  if [[ -f /etc/os-release ]]; then
    mapfile -t _os < <(
      ( . /etc/os-release
        printf '%s\n' \
          "${ID:-unknown}" \
          "${VERSION_ID:-unknown}" \
          "${PRETTY_NAME:-Unknown OS}" \
          "${VERSION_CODENAME:-unknown}" )
    )
    PLATFORM_OS_ID="${_os[0]:-unknown}"
    PLATFORM_OS_VERSION_ID="${_os[1]:-unknown}"
    PLATFORM_OS_PRETTY="${_os[2]:-Unknown OS}"
    PLATFORM_OS_CODENAME="${_os[3]:-unknown}"
  else
    PLATFORM_OS_ID="unknown"
    PLATFORM_OS_VERSION_ID="unknown"
    PLATFORM_OS_PRETTY="Unknown OS"
    PLATFORM_OS_CODENAME="unknown"
  fi
}

platform_supported_matrix_string() {
  echo "Ubuntu 22.04/24.04/26.04"
}

platform_is_supported_os() {
  if [[ "${PLATFORM_OS_ID:-}" != "ubuntu" ]]; then
    return 1
  fi
  case "${PLATFORM_OS_VERSION_ID:-}" in
    "22.04"|"24.04"|"26.04") return 0 ;;
    *) return 1 ;;
  esac
}

# PHP version shipped by the Ubuntu release itself (no third-party repository).
# shellcheck disable=SC2120 # optional codename argument; defaults to this host
platform_native_php_version() {
  case "${1:-${PLATFORM_OS_CODENAME:-}}" in
    jammy) echo 8.1 ;;
    noble) echo 8.3 ;;
    resolute) echo 8.5 ;;
    *) echo "" ;;
  esac
}

# Whether the ondrej/php PPA publishes packages for this release. A new
# Ubuntu release is covered some months after it ships.
# shellcheck disable=SC2120 # optional codename argument; defaults to this host
platform_ondrej_php_available() {
  local codename="${1:-${PLATFORM_OS_CODENAME:-}}"
  [[ -n "$codename" ]] || return 1
  curl -fsS -o /dev/null --max-time 15 \
    "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${codename}/Release" 2>/dev/null
}

# Default PHP for a new host: 8.2 where the PPA provides it, otherwise the
# release's own PHP.
platform_default_php_version() {
  if platform_ondrej_php_available; then
    echo 8.2
  else
    platform_native_php_version
  fi
}

platform_has_tty() {
  [[ -t 1 && -r /dev/tty && -w /dev/tty ]]
}

platform_init_colors() {
  if platform_has_tty; then
    GREEN=$'\e[32m'
    RED=$'\e[31m'
    RESET=$'\e[0m'
  else
    GREEN=""
    RED=""
    RESET=""
  fi
}

platform_print_os_support_status() {
  platform_init_colors
  local supported_matrix
  supported_matrix=$(platform_supported_matrix_string)
  if platform_is_supported_os; then
    if platform_has_tty; then
      printf "[OK] %sOS: %s (%s %s %s)%s — supported\n" "${GREEN}" "${PLATFORM_OS_PRETTY}" "${PLATFORM_OS_ID}" "${PLATFORM_OS_VERSION_ID}" "${PLATFORM_OS_CODENAME}" "${RESET}" >/dev/tty
    else
      printf "[OK] OS: %s (%s %s %s) — supported\n" "${PLATFORM_OS_PRETTY}" "${PLATFORM_OS_ID}" "${PLATFORM_OS_VERSION_ID}" "${PLATFORM_OS_CODENAME}"
    fi
    return 0
  else
    local msg="[ERROR] OS: %s (%s %s %s) — NOT supported. Supported: %s\n"
    if platform_has_tty; then
      printf "$msg" "${RED}${PLATFORM_OS_PRETTY}${RESET}" "${PLATFORM_OS_ID}" "${PLATFORM_OS_VERSION_ID}" "${PLATFORM_OS_CODENAME}" "${supported_matrix}" >/dev/tty
    else
      printf "$msg" "${PLATFORM_OS_PRETTY}" "${PLATFORM_OS_ID}" "${PLATFORM_OS_VERSION_ID}" "${PLATFORM_OS_CODENAME}" "${supported_matrix}"
    fi
    return 1
  fi
}

platform_assert_supported_os() {
  platform_detect_os
  if platform_is_supported_os; then
    return 0
  fi
  platform_print_os_support_status
  return 1
}
