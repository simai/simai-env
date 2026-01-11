#!/usr/bin/env bash

platform_detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    PLATFORM_OS_ID="${ID:-unknown}"
    PLATFORM_OS_VERSION_ID="${VERSION_ID:-unknown}"
    PLATFORM_OS_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"
    PLATFORM_OS_CODENAME="${VERSION_CODENAME:-unknown}"
  else
    PLATFORM_OS_ID="unknown"
    PLATFORM_OS_VERSION_ID="unknown"
    PLATFORM_OS_PRETTY="Unknown OS"
    PLATFORM_OS_CODENAME="unknown"
  fi
}

platform_supported_matrix_string() {
  echo "Ubuntu 22.04/24.04"
}

platform_is_supported_os() {
  if [[ "${PLATFORM_OS_ID:-}" != "ubuntu" ]]; then
    return 1
  fi
  case "${PLATFORM_OS_VERSION_ID:-}" in
    "22.04"|"24.04") return 0 ;;
    *) return 1 ;;
  esac
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
