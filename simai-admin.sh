#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADMIN_DIR="${SCRIPT_DIR}/admin"
LOG_FILE=${LOG_FILE:-/var/log/simai-admin.log}

source "${ADMIN_DIR}/core.sh"
source "${ADMIN_DIR}/menu.sh"
source "${ADMIN_DIR}/lib/site_utils.sh"

load_command_modules "${ADMIN_DIR}/commands"

usage() {
  cat <<USAGE
simai-admin.sh <section> <command> [options]
simai-admin.sh menu      # interactive menu

Examples:
  simai-admin.sh site add --domain example.com --project-name myapp --php 8.2
  simai-admin.sh db create --name simai_app --user simai --pass secret
USAGE
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
    -h|--help)
      usage
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
