#!/usr/bin/env bash
set -euo pipefail

self_update_handler() {
  local updater="${SCRIPT_DIR}/update.sh"
  if [[ ! -x "$updater" ]]; then
    error "Updater not found or not executable at ${updater}"
    exit 1
  fi
  info "Running updater ${updater}"
  "$updater"
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    info "Reloading admin menu after update"
    exec "${SCRIPT_DIR}/simai-admin.sh" menu
  fi
}

self_version_handler() {
  local local_version="(unknown)"
  local version_file="${SCRIPT_DIR}/VERSION"
  [[ -f "$version_file" ]] && local_version="$(cat "$version_file")"

  local remote_version
  remote_version=$(curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/VERSION 2>/dev/null || true)
  [[ -z "$remote_version" ]] && remote_version="(unavailable)"

  local status="n/a"
  if [[ "$remote_version" != "(unavailable)" ]]; then
    if [[ "$local_version" == "$remote_version" ]]; then
      status="up to date"
    else
      status="update available"
    fi
  fi

  local sep="+----------------------+----------------------+"
  printf "%s\n" "$sep"
  printf "| %-20s | %-20s |\n" "Local version" "$local_version"
  printf "| %-20s | %-20s |\n" "Remote version" "$remote_version"
  printf "| %-20s | %-20s |\n" "Status" "$status"
  printf "%s\n" "$sep"
}

register_cmd "self" "update" "Update simai-env/admin scripts" "self_update_handler" "" ""
register_cmd "self" "version" "Show local and remote simai-env version" "self_version_handler" "" ""
