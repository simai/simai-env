#!/usr/bin/env bash
set -euo pipefail

self_update_handler() {
  local updater="${SCRIPT_DIR}/update.sh"
  if [[ ! -x "$updater" ]]; then
    error "Updater not found or not executable at ${updater}"
    return 1
  fi
  info "Running updater ${updater}"
  progress_init 2
  progress_step "Downloading and applying update"
  "$updater"
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    progress_step "Reloading admin menu"
    info "Reloading admin menu after update"
    return "${SIMAI_RC_MENU_RELOAD:-88}"
  fi
  progress_done "Update completed"
  return 0
}

self_bootstrap_handler() {
  parse_kv_args "$@"
  local php="${PARSED_ARGS[php]:-8.2}"
  local mysql="${PARSED_ARGS[mysql]:-mysql}"
  local node="${PARSED_ARGS[node-version]:-20}"
  info "Repair Environment: installs/repairs base packages and may reload services; sites are not removed."
  progress_init 2
  progress_step "Running bootstrap (php=${php}, mysql=${mysql}, node=${node})"
  if ! "${SCRIPT_DIR}/simai-env.sh" bootstrap --php "$php" --mysql "$mysql" --node-version "$node"; then
    progress_done "Bootstrap failed"
    return 1
  fi
  progress_done "Bootstrap completed"
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

  local GREEN=$'\e[32m' RED=$'\e[31m' RESET=$'\e[0m'
  local status_padded
  status_padded=$(printf "%-20s" "$status")
  local status_colored="$status_padded"
  if [[ "$status" == "up to date" ]]; then
    status_colored="${GREEN}${status_padded}${RESET}"
  elif [[ "$status" == "update available" ]]; then
    status_colored="${RED}${status_padded}${RESET}"
  fi

  local sep="+----------------------+----------------------+"
  printf "%s\n" "$sep"
  printf "| %-20s | %-20s |\n" "Local version" "$local_version"
  printf "| %-20s | %-20s |\n" "Remote version" "$remote_version"
  printf "| %-20s | %-20s |\n" "Status" "$status_colored"
  printf "%s\n" "$sep"
}

register_cmd "self" "update" "Update simai-env/admin scripts" "self_update_handler" "" ""
register_cmd "self" "version" "Show local and remote simai-env version" "self_version_handler" "" ""
register_cmd "self" "bootstrap" "Repair Environment (base stack: nginx/php/mysql/certbot/etc.)" "self_bootstrap_handler" "" "php= mysql= node-version="
