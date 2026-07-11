#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADMIN_DIR="${SCRIPT_DIR}/admin"
LOG_FILE=${LOG_FILE:-/var/log/simai-admin.log}

source "${ADMIN_DIR}/core.sh"
source "${ADMIN_DIR}/menu.sh"
source "${ADMIN_DIR}/lib/profile_utils.sh"
source "${ADMIN_DIR}/lib/scheduler_utils.sh"
source "${ADMIN_DIR}/lib/perf_utils.sh"
source "${ADMIN_DIR}/lib/site_utils.sh"
source "${SCRIPT_DIR}/lib/update_channel.sh"
source "${ADMIN_DIR}/lib/profile_apply.sh"
source "${ADMIN_DIR}/lib/apt_utils.sh"
source "${ADMIN_DIR}/lib/php_utils.sh"
source "${ADMIN_DIR}/lib/fix_utils.sh"
source "${ADMIN_DIR}/lib/doctor_utils.sh"
source "${ADMIN_DIR}/lib/db_utils.sh"
source "${ADMIN_DIR}/lib/access_utils.sh"

load_command_modules "${ADMIN_DIR}/commands"

usage() {
  local requested_section="${1:-}"
  cat <<USAGE
simai-admin.sh <section> <command> [options]
simai-admin.sh menu      # interactive menu
simai-admin.sh help [section]

Examples:
  simai-admin.sh site add --domain your-domain.tld --profile generic --php 8.2
  simai-admin.sh site db-create --domain your-domain.tld --dry_run yes
  simai-admin.sh site db-create --domain your-domain.tld --confirm yes
USAGE
  local section name key flags required optional
  if [[ -n "$requested_section" ]]; then
    if ! list_sections | grep -Fxq "$requested_section"; then
      echo "Unknown help section: ${requested_section}" >&2
      return 1
    fi
    echo
    echo "Commands in ${requested_section}:"
    for name in $(list_commands_for_section "$requested_section"); do
      key="${requested_section}:${name}"
      flags="${CMD_FLAGS[$key]:-}"
      [[ " ${flags} " == *" menu:hidden " ]] && continue
      required="${CMD_REQUIRED[$key]:-}"
      optional="${CMD_OPTIONAL[$key]:-}"
      printf "  %-28s %s\n" "${requested_section} ${name}" "${CMD_DESCRIPTIONS[$key]:-}"
      [[ -n "$required" ]] && printf "    required: %s\n" "$required"
      [[ -n "$optional" ]] && printf "    optional: %s\n" "$optional"
    done
    return 0
  fi
  echo
  echo "Sections (use 'simai-admin.sh help <section>' for commands):"
  list_sections | while IFS= read -r section; do
    printf "  %s\n" "$section"
  done
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  ensure_root
  require_supported_os

  local cmd="$1"
  shift

  case "$cmd" in
    menu)
      run_menu "$@"
      ;;
    -h|--help|help)
      usage "${1:-}"
      ;;
    *)
      local section="$cmd"
      local subcommand="${1:-}"
      if [[ -z "$subcommand" ]]; then
        usage
        exit 1
      fi
      shift
      run_command "$section" "$subcommand" "$@"
      ;;
  esac
}

main "$@"
