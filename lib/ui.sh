#!/usr/bin/env bash
set -euo pipefail

SIMAI_UI_MODE="${SIMAI_UI_MODE:-human}"
SIMAI_UI_COLOR="${SIMAI_UI_COLOR:-auto}"

_ui_supports_color() {
  if [[ "${NO_COLOR:-}" != "" ]]; then
    return 1
  fi
  case "${SIMAI_UI_COLOR}" in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ -t 1 ]]
}

_ui_color() {
  local code="$1"
  if _ui_supports_color; then
    printf '\033[%sm' "$code"
  fi
}

ui_init() {
  :
}

ui_info() {
  printf "%s[INFO]%s %s\n" "$(_ui_color "36")" "$(_ui_color "0")" "$*"
}

ui_success() {
  printf "%s[OK]%s %s\n" "$(_ui_color "32")" "$(_ui_color "0")" "$*"
}

ui_warn() {
  printf "%s[WARN]%s %s\n" "$(_ui_color "33")" "$(_ui_color "0")" "$*"
}

ui_error() {
  printf "%s[ERROR]%s %s\n" "$(_ui_color "31")" "$(_ui_color "0")" "$*"
}

ui_step() {
  local idx="${1:-?}"
  local msg="${2:-}"
  printf "[%s] %s\n" "$idx" "$msg"
}

ui_section() {
  local title="$1"
  printf "\n%s\n" "$title"
}

ui_result_table() {
  ui_section "Result"
  print_kv_table "$@"
}

ui_result_info() {
  ui_section "Result"
  ui_info "$@"
}

ui_result_warn() {
  ui_section "Result"
  ui_warn "$@"
}

ui_next_steps() {
  ui_section "Next steps"
}

ui_kv() {
  local key="$1"
  local value="${2:-}"
  printf "  %-18s %s\n" "${key}:" "$value"
}

ui_header() {
  local title="$1"
  printf "\n%s\n" "$title"
}
